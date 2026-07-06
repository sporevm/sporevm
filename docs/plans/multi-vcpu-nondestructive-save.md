---
status: landed
last_reviewed: 2026-07-05
spec_refs:
  - docs/lifecycle.md
  - docs/spore-format.md
  - docs/state-portability.md
  - SECURITY.md
  - src/lifecycle.zig
  - src/monitor.zig
  - src/run.zig
  - src/kvm/vm.zig
  - src/hvf/vm.zig
  - src/disk_layer.zig
  - scripts/smoke-multi-vcpu.sh
related_plans:
  - docs/plans/spore-naming-cli-ux.md
  - docs/plans/multi-vcpu.md
  - docs/plans/multi-vcpu-fork.md
---

# Multi-vCPU Non-Destructive `spore save`

## Summary

`spore save NAME --out DIR` (non-destructive: the named VM keeps running)
currently fails closed for multi-vCPU VMs. The guard is a lifecycle-level
over-restriction deferred from the spore-naming rename PR
(`docs/plans/spore-naming-cli-ux.md`, "Deferred Work"): the rename shipped
fail-closed rather than silently degrading to a consuming `--stop` save.

**The core discovery of this investigation: the hypervisor capability the
guard protects already exists on both backends.** Multi-vCPU
quiesce → capture → resume is implemented today in `snapshotMultiKvmAndContinue`
(`src/kvm/vm.zig`) and the inline `continue_after` branch of the HVF multi-vCPU
run loop (`src/hvf/vm.zig`), and it is exercised in production by
`spore fork --vm` on diskless multi-vCPU named VMs. This feature does **not**
require new hypervisor infrastructure. It requires narrowing the lifecycle
guard, proving the disk-backed and networked continue-after-capture paths that
fork never exercised, extending smoke coverage, and measuring pause duration.

No missing-capability blocker was found, so this plan proceeds to sliced
implementation. Per the task contract, Phase 1 ships this plan doc only, flagged
for review, before any feature code lands.

## Phase 1 — Discovery

### 1. Why the guard exists and how the live-save path flows

`spore save NAME` without `--stop` flows:

```diagram
saveCli (src/lifecycle.zig)
  └─ saveNamed              temp sibling dir + atomic rename publish
       └─ saveContinueNamed ← GUARD: if spec.vcpus != 1 -> UnsupportedSnapshotMode
            └─ sendSnapshotRequest(control.sock, out_dir)   type="snapshot", continue=true
                 └─ monitor ExecServer "snapshot" request
                      ├─ requires continue=true (rejects continue=false)
                      └─ state = pending_snapshot
                           └─ run loop poll() -> .snapshot{ dir, continue_after=true }
                                ├─ KVM multi: snapshotMultiKvmAndContinue -> takeSnapshotV1
                                └─ HVF multi: inline continue branch    -> takeSnapshotV1
```

The `saveContinueNamed` guard is `if (spec.value.vcpus != 1) return
error.UnsupportedSnapshotMode`, mapped by `saveCli` to
"non-destructive save is not supported for this VM yet; use `spore save NAME
--out DIR --stop`". It is the **only** vCPU gate in the non-destructive save
path. Everything below it already handles N vCPUs.

Two other `vcpus != 1` checks exist but do **not** apply to this path:

- `src/kvm/vm.zig` (`config.continue_after_capture`) and `src/hvf/vm.zig`
  (`config.continue_after_capture` / `dirty_tracking.enabled`) reject
  multi-vCPU only for the **one-shot `run --save --continue-after-save`**
  (`execute`) path. The monitor path (`executeMonitor`) never sets
  `continue_after_capture`; it uses the control-socket `.snapshot` action with
  `request.continue_after`, which the multi-vCPU run loops already service.

**Comparison with the consuming (`--stop`) path.** `saveStopNamed` →
`sendSuspendRequest` → monitor `"suspend"` (no `continue`) → run loop
`.snapshot{ continue_after=false }`. On multi-vCPU this reaches the same
`takeSnapshotV1` capture, then returns `.snapshotted` and the monitor process
exits. The difference between `--stop` and non-destructive is exactly the
resume-after-capture step:

| Step | `--stop` (`suspend`) | non-destructive (`snapshot`) |
| --- | --- | --- |
| quiesce all vCPUs at one barrier | yes | yes |
| capture per-vCPU + GIC + timers + devices + RAM | `takeSnapshotV1` | `takeSnapshotV1` (identical) |
| after capture | return `.snapshotted`, monitor exits | `clearSnapshot`, resume vCPUs, keep serving |
| VM survives | no | yes |

`--stop` already runs `takeSnapshotV1` for multi-vCPU disk/diskless/network
VMs, and single-vCPU non-destructive `save` already runs the seal-then-resume
sequence. Multi-vCPU non-destructive save is the intersection of two paths that
each ship today; it has simply never been enabled or tested as a combination.

**Relationship to `UnsupportedNamedForkVcpu`.** The fork CLI maps a
`fork`-specific error to "source uses a fork topology or GIC state this backend
cannot mint safely yet" (`src/lifecycle.zig`), but that `UnsupportedNamedForkVcpu`
mapping arm is now effectively dead: the actual error raised during child
minting is `error.UnsupportedVcpuCount` from `forkGicStateV1` (`src/spore.zig`),
which fires only when a manifest-v1 GIC state is neither `backend_private` nor
`gicv3_multi` (i.e. a single-vCPU-shaped `.gicv3` blob in a v1 manifest). For a
real multi-vCPU source `forkGicStateV1` does **not** reject: it returns
`backend_private` unchanged or rewrites `gicv3_multi` with the child generation
SPI. Save is unrelated regardless: it never calls `spore.fork` or
`forkGicStateV1`, does not mint a child, and does not rewrite GIC identity — it
captures the live GIC as-is via `takeSnapshotV1`. The root causes are **not**
shared: save is strictly simpler than fork. Fork itself is out of scope.

### 2. Multi-vCPU state captured consistently and resumed, per backend

All of this is already implemented and exercised by `fork --vm` (diskless);
the plan verifies it end-to-end for save (including disk/network):

- **All vCPUs quiesced at one point.** `pauseKvmVcpusForSnapshot` /
  `pauseHvfVcpusForSnapshot` set a `snapshot_requested` flag, wake every vCPU,
  and spin until each vCPU thread has parked itself (`snapshot_paused`). Device
  MMIO is handled on the vCPU threads under a device lock, so once all vCPUs
  park there is no concurrent device or DMA activity: the capture point is
  globally consistent.
- **Per-vCPU architectural state.** `takeSnapshotV1` writes manifest v1
  `machine.vcpus[]` with stable `index`/`mpidr`, GPRs, `pc`/`cpsr`, FP/SIMD,
  EL1 sysregs, ICC registers, and vtimer — one entry per vCPU.
- **GIC distributor/redistributor.** KVM emits portable `gicv3_multi` (global
  distributor + per-MPIDR redistributors + owner-tagged PPI line levels). HVF
  emits the tagged `backend_private` `hv_gic_state_v0` blob (same-HVF only).
  Both are captured by `takeSnapshotV1` unchanged.
- **Virtual timer/counter across vCPUs.** Each vCPU's vtimer is captured in the
  platform `counter_frequency_hz` domain and re-anchored on restore
  (same-frequency only).
- **In-flight IPIs / interrupt state.** Carried by GIC line levels
  (owner-tagged PPIs for SGIs/IPIs) plus per-vCPU ICC registers. Because all
  vCPUs park at the barrier, no IPI is mid-delivery outside GIC/ICC state.
- **Secondary vCPU online/offline (PSCI).** A parked vCPU that never came
  online has its architectural state captured as-is; restore brings each vCPU
  up through the normal bring-up path and applies saved state, so an
  offline-at-capture secondary resumes offline. HVF's multi-vCPU loop already
  models PSCI actions (`handlePsciMulti`).

Conclusion: no per-backend state class is unhandled. HVF remains
same-backend-only for GIC (documented, identical to `--stop` and fork today).

### 3. Memory capture strategy while the VM continues

The monitor snapshot-and-continue path uses **full pause-copy**. `executeMonitor`
does not enable dirty tracking (`dirty_tracking` and `snapshot_dir` are unset at
boot), so each save quiesces all vCPUs and then `takeSnapshotV1` walks RAM,
elides zero chunks, BLAKE3-addresses the rest, and records them, before
resuming. Pause duration is proportional to RAM size (hash + write of non-zero
2 MiB chunks). This is the same pause profile `fork --vm` already accepts.

Note the pause scans the **full boot RAM span**, and named VMs default to
`--memory auto` = 16 GiB (`src/lifecycle.zig` help; `memory_config.auto_bytes`)
with no virtio-mem in the monitor path (`executeMonitor` passes
`opts.memory.bytes` directly). So a default multi-vCPU named VM pauses across a
16 GiB scan, not a few GiB. Pause measurement (verification below) must include
the default `auto` case, not only a small explicit `--memory`, or the recorded
numbers will understate real-world pauses. Also, for the whole pause the monitor
is in `active_snapshot` state and other control requests (`exec`, `copy`)
receive "monitor busy" — parity with fork/`--stop`, but worth stating.

Dirty tracking (see `scripts/benchmark-kvm-dirty-tracking.sh`) could shorten the
pause by copying only changed pages, but it is deliberately **out of scope** for
this change: it is a memory-capture optimization, is currently gated to
single-vCPU, and would expand the guest-memory scan attack surface. The plan
sticks with full pause-copy and instead **measures and bounds** the pause for a
multi-GiB guest (verification below). If measured pause is unacceptable for a
target size, that is a follow-up dirty-tracking slice, not a blocker for
enabling the feature.

### 4. Support matrix

Save-time capability (what a supported host can capture from a running
multi-vCPU named VM):

| Backend | diskless | `--image` writable rootfs | `--rootfs PATH` | networked | Save result |
| --- | --- | --- | --- | --- | --- |
| KVM | enabled | enabled | enabled | enabled | portable `gicv3_multi` v1 spore |
| HVF | enabled | enabled | enabled | enabled | `backend_private` GIC v1 spore |

Restore-time direction (unchanged by this work; enforced at restore, not save):

| Direction | Status |
| --- | --- |
| KVM → KVM | supported (portable v1) |
| HVF → HVF | supported (same-backend v1) |
| KVM → HVF | fails closed: counter-frequency mismatch / HVF GIC gaps |
| HVF → KVM | fails closed: HVF produces backend-private GIC |

Combinations that still fail closed after this change, with the exact intended
CLI error:

- **Cross-backend restore** of a multi-vCPU spore — already fails closed at
  restore time on platform/GIC/counter mismatch. Not a save-time error.
- **Disk-backed identity missing** — `saveContinueNamed` keeps
  `MissingRootfsIdentity`: "spore save: disk-backed lifecycle save requires
  recorded immutable rootfs identity".
- **Backend returns `UnsupportedVcpuCount`** for a config it cannot capture —
  must map to a distinct, accurate CLI error, not the current misleading
  "use `--stop`" text (which would be a lie once `--stop` and non-destructive
  are equally capable). See slice 2.

Note: unlike `fork --vm`, non-destructive save does **not** reject networked or
disk-backed multi-vCPU VMs. `save --stop` already supports both for multi-vCPU,
and the live gateway simply keeps running across a non-destructive save (the
manifest records policy only, never live flows).

### 5. Slices

The guard lives in `saveContinueNamed`, above the backend, and both backends already
implement the capability, so a per-backend code gate is the wrong shape. There
is exactly **one** effective hypervisor per host — `monitorBackendSupported`
resolves HVF on Apple Silicon and KVM on Linux/aarch64, mutually exclusive — so
a "KVM enabled, HVF fail-closed" intermediate is not a backend switch in code; it
would be a `builtin.os.tag` platform check that exists only to be deleted in a
follow-up. Worse, a gate keyed on the raw spec backend string is buggy: named
create stores `options.backend.name()`, which is the literal `"auto"` for the
common default case (`src/lifecycle.zig`), not `"kvm"`/`"hvf"`.

Therefore the recommended shape is a **single unconditional guard removal**:

- **Slice — enable multi-vCPU non-destructive save.** Delete
  `if (spec.value.vcpus != 1) return error.UnsupportedSnapshotMode` in
  `saveContinueNamed`; keep `MissingRootfsIdentity`. Update `saveCli` error mapping
  so the "use `--stop`" text no longer claims multi-vCPU non-destructive save is
  unsupported (it is now supported on every host SporeVM runs on). Extend
  `scripts/smoke-multi-vcpu.sh` (see Verification) and its `mise.toml` task
  description.

The **release gate stays per-platform hardware evidence**, not a code split: run
the extended smoke on an ARM64 KVM host (portable `gicv3_multi`, matches existing
`state-portability.md` evidence) and on Apple Silicon HVF (same-backend restore,
identical to its `--stop`/fork behavior today), and report which platforms were
and were not exercised. If a reviewer nonetheless wants an intermediate
fail-closed state for one platform, it must be an explicit
`builtin.os.tag`-based platform gate with an accurate message — but this plan
recommends against it because both backends are already verified capable in code.

## Phase 2 — Implementation (each slice green)

### Guard and error mapping

- In `saveContinueNamed` (`src/lifecycle.zig`), delete the blanket
  `if (spec.value.vcpus != 1) return error.UnsupportedSnapshotMode`. Keep the
  existing `MissingRootfsIdentity` check unchanged. Do **not** replace it with a
  gate keyed on `spec.backend`: named create stores `options.backend.name()`,
  which is the literal `"auto"` in the default case, so a string-compare gate
  would misclassify most VMs. Since exactly one backend is effective per host,
  no per-backend gate is needed.
- Update `saveCli` error mapping: `error.UnsupportedSnapshotMode` is now only a
  defensive mapping, but its message must no longer claim multi-vCPU is the
  reason. If any narrower fail-closed case is later needed, that decision
  must be made **client-side in `saveContinueNamed`** before sending the request,
  because a backend `UnsupportedVcpuCount` raised inside the monitor process
  only reaches the client as the generic "monitor backend stopped" text and
  cannot carry a precise message. Do not rely on surfacing backend errors for
  fail-closed wording.
- Preserve fail-closed: no path may silently fall back to `--stop`/consuming
  behavior.

### Publish semantics and failure safety

- **Failed capture is fail-loud-and-die, and that is the accepted contract**
  (parity with single-vCPU today). On a capture error both backends call
  `state.finish(.{ .err = err })` (`src/kvm/vm.zig`, `src/hvf/vm.zig`), which
  sets `stop`, joins all vCPU threads, and terminates the monitor process; the
  save client receives an error (the monitor's `failOutstanding("monitor
  backend stopped")` in `src/monitor.zig`). The named VM does **not** survive a
  failed capture. This matches single-vCPU non-destructive save, where a failed
  `takeSnapshot` propagates out of `run()` and ends the monitor. The plan
  therefore does **not** claim the VM keeps running after a failed capture; it
  guarantees only fail-closed publish (no partial spore) plus a loud error that
  names the dead VM — never a silent kill or a silent `--stop` fallback.
  Document this contract in `docs/lifecycle.md`. Reworking capture failure into
  a genuine resume-on-failure (VM survives a failed save) is a larger,
  per-backend change and is explicitly out of scope for this plan.
- `saveNamed`'s temp-sibling + atomic-rename publish still guarantees no partial
  spore at `--out`: the temp dir is deleted on any error before rename.

### Disk-backed continue correctness (the one genuinely new combination)

`sealDisk` (`src/disk_layer.zig`) is read-only with respect to the live COW
head: it reads dirty clusters and writes **content-addressed copies** into the
spore directory. It does not mutate or reset the live head. Therefore continued
guest writes after resume cannot corrupt the already-sealed point-in-time spore.
Repeated saves re-seal overlapping clusters idempotently
(`writeFileAllIfMissing`). This combination (multi-vCPU + disk seal + resume) is
the intersection of multi-vCPU `--stop` seal and single-vCPU non-destructive
seal, both shipping today, but must be proven by the extended smoke.

### Manifest and security

- No manifest format change is required. Multi-vCPU save produces the existing
  manifest v1 (`gicv3_multi` on KVM, `backend_private` on HVF). No new field, no
  new normalized state, no raw KVM/HVF structs (HVF blob remains the documented
  tagged escape hatch).
- No new parser of attacker-influenced spore data is introduced, so no new fuzz
  target is required by `SECURITY.md`. If implementation surprises force any new
  parse of spore-file bytes, a fuzz target ships in the same change.
- Restore must yield the original vCPU count and consistent state via
  `spore restore --name` and `spore run --from`; sessions propagate as today.

## Verification

- `mise run build` and `mise run test` green at every slice.
- Extend `scripts/smoke-multi-vcpu.sh` (behind the existing
  `SPORE_SMOKE_NAMED_LIFECYCLE` block or a sibling block) and update the
  `smoke:multi-vcpu` task description in `mise.toml`:
  Diskless case:
  1. `spore create` a multi-vCPU exec-ready named VM, `spore save NAME --out
     DIR` **without** `--stop`, assert the source remains registered, restore
     the spore as `NAME2` while the source remains alive, and assert `nproc`
     equals the original vCPU count.
  2. `spore create` a multi-vCPU named VM running a ticking workload
     (monotonic counter to a file, like the fork counter example).
  3. `spore save NAME --out DIR` **without** `--stop`.
  4. Assert the VM is still registered/running and still ticking (compare a
     later tick to an earlier one via `spore exec`).
  5. Remove the source VM, then `spore restore DIR --name NAME2` and assert
     the saved manifest records the original vCPU count and the restored VM
     ticks.
  6. Assert single-vCPU non-destructive save is unchanged (regression).

  Disk-backed case (this is the one genuinely new combination — do not skip):
  7. `spore create` a multi-vCPU named VM with `--image` (writable rootfs) and,
     separately, with `--rootfs PATH` (exact artifact), running a workload that
     writes to disk.
  8. `spore save NAME --out DIR` without `--stop`, then have the guest write
     *more* to disk (`spore exec`), then `spore restore DIR --name NAME2` and
     assert the restored VM sees exactly the point-in-time disk contents (the
     post-save writes must NOT appear in the restored spore).
  9. Take a **second** non-destructive save of the same still-running VM to
     exercise the idempotent re-seal path (`sealDisk` never clears the live
     head's dirty flags), and assert both saved spores restore correctly.
- Run the smoke on real hardware for every platform; report which platforms were
  and were not tested (KVM ARM64 host and/or Apple Silicon HVF).
- Measure and record pause duration for both a small explicit `--memory` guest
  and the **default `--memory auto` (16 GiB) case**, to confirm the full
  pause-copy window is bounded and sane; note numbers in the PR.
- Confirm no regression in `save --stop`, `fork --vm`, `run --from`, and
  `attach` for multi-vCPU.

## Docs

- `docs/lifecycle.md`: replace "Non-destructive save currently requires a
  single-vCPU VM; multi-vCPU named VMs must use `--stop`" with the real support
  matrix (both backends, disk/diskless/network, HVF same-backend restore).
- `docs/plans/spore-naming-cli-ux.md` "Deferred Work": mark multi-vCPU
  non-destructive save as landed (per slice) and point to this plan.
- Keep this plan's status/frontmatter current as slices land
  (`proposed` → `active` → `landed`).

## Open Questions For Review

1. Guard shape — **resolved (recommendation): unconditional guard removal.**
   Because exactly one backend is effective per host and both are already
   verified capable in code, a per-backend gate degenerates to a throwaway
   platform check, and a `spec.backend` string gate is buggy against the default
   `"auto"` value. The release gate is per-platform hardware smoke evidence, not
   a code split. Flagged here only for explicit reviewer sign-off.
2. Pause-duration acceptance threshold: what guest RAM size / pause budget makes
   full pause-copy acceptable before a dirty-tracking follow-up is warranted?
3. Is enabling networked multi-vCPU non-destructive save in the same slice
   acceptable, or should it be gated behind its own smoke evidence like the
   backend split? (`save --stop` already supports it, so parity argues for
   enabling it.)

## Implementation Status

Slice landed (`feat: multi-vCPU non-destructive spore save`):

- `saveContinueNamed` (`src/lifecycle.zig`): removed the `vcpus != 1` gate; kept
  `MissingRootfsIdentity`. No per-backend gate (spec backend is `"auto"` by
  default; one backend is effective per host).
- `saveCli` (`src/lifecycle.zig`): the `UnsupportedSnapshotMode` message no
  longer claims multi-vCPU is unsupported (that arm is now only reachable for a
  non-CLI `continue_after == false` request).
- `scripts/smoke-multi-vcpu.sh` + `mise.toml`: the `SPORE_SMOKE_NAMED_LIFECYCLE`
  block now saves an exec-ready multi-vCPU named VM **without** `--stop`,
  restores it under a second name while the source remains alive, and asserts
  the restored VM reports the right `nproc`. It also creates a multi-vCPU VM
  running a `/tick` shell workload, saves it without `--stop`, asserts the
  source VM is still registered (`spore ls`) and still ticking, removes the
  source, restores the saved spore, and asserts the restored VM keeps ticking
  from the captured workload state. The single-vCPU regression and `save --stop`
  paths are retained unchanged.
- Docs: `docs/lifecycle.md` support matrix updated;
  `docs/plans/spore-naming-cli-ux.md` Deferred Work marked landed.

Verified during implementation: `mise run build` and `mise run test` green.
Follow-up local Apple Silicon HVF testing on 2026-07-06 exercised the
non-destructive save path directly: exec-ready multi-vCPU save restores while
the source remains alive, active-workload multi-vCPU save leaves the source
registered and ticking after save, and the saved active workload restores after
the source is removed. After PR #375 stabilized restored file-stdio starts, the
full `SPORE_SMOKE_NAMED_LIFECYCLE=1 mise run smoke:multi-vcpu` task passes
repeatedly on Apple Silicon HVF. ARM64 KVM real-hardware coverage and
pause-duration measurements still need to land before release.

Follow-up (not blocking this slice):

- **Disk-backed multi-vCPU non-destructive smoke.** The extended
  `smoke-multi-vcpu.sh` covers the diskless ticking case the task specifies.
  Disk-backed (`--image` writable rootfs / `--rootfs`) non-destructive save
  correctness rests on the `sealDisk` read-only argument (§"Disk-backed continue
  correctness") and shares `takeSnapshotV1` with the multi-vCPU `save --stop`
  path that `smoke:writable-rootfs` and the multi-vCPU `--stop` smoke already
  exercise. A dedicated disk-backed non-destructive save + write-after-save +
  restore case belongs in `scripts/smoke-writable-rootfs.sh` (which already has
  image/rootfs infra) and should land on real hardware.
- Pause-duration measurement for a small explicit `--memory` guest and the
  default `--memory auto` (16 GiB) case, recorded in the PR.
- Concurrent restore of an active multi-vCPU workload while the source VM keeps
  running. Local HVF testing on 2026-07-06 found the saved artifact restores
  cleanly after removing the source, but source-and-restored active copies
  running side by side can leave the restored monitor unable to complete
  `spore exec` (`MonitorRequestFailed`). Treat that as a separate restore/fork
  correctness investigation rather than proof for this enablement slice.

## Deferred / Out Of Scope

- Dirty-tracking-accelerated multi-vCPU capture (shorter pause).
- Disk-backed or networked named **fork** (`fork --vm`) — separate limitation.
- Cross-backend multi-vCPU restore (counter-frequency + HVF portable GIC).
- Any manifest format change.
