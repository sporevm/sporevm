---
status: landed
last_reviewed: 2026-07-13
spec_refs:
  - docs/memory.md
  - docs/spore-format.md
  - docs/fanout.md
  - SECURITY.md
  - src/attach.zig
  - src/fanout.zig
  - src/ram_restore.zig
  - src/run.zig
  - src/spore.zig
---

# Automatic Local RAM Backing Follow-Up

## Current Contract

The implementation has landed. Product restore paths automatically map
same-host `ram.backing` only when `ram.backing.proof` validates against the
canonical memory index identity, opened file identity, backing metadata, and the
host-local runtime key. Missing, symlinked, non-regular, or size-mismatched
optional paths, and stale, foreign, malformed, or mismatched proofs, fall back
to verified chunks.

Fallback is limited to the optional acceleration hint being absent or unsafe.
Malformed authoritative memory/index/backing metadata, allocation failure,
unexpected host I/O, platform mismatch, corrupt chunks, and backend restore
failure remain errors rather than being reclassified as chunk fallback.

Linux proof creation first reuses an existing fs-verity digest without changing
permissions. For a new owned read-only backing it temporarily adds owner-write,
enables and measures verity through the opened fd, restores the exact original
mode, and revalidates device, inode, owner, and size before publishing the
proof. Schema v2 binds the proof to the post-enable mtime and digest and
re-stats that exact identity; v1 and the existing-verity fast path retain exact
mtime stability. Errors attempt to restore the mode and publish no proof. A
crash can leave only an
unproved optional backing; verified chunks remain authoritative.

`spore fork` hard-links a proof-valid parent backing file into children and
writes child-local proofs. It retains the proven parent fd across the batch and
checks each opened child link against the proof-bound parent identity before
writing that proof. Only classified optional hard-link unavailability or a
conflicting child proof drops the hint; identity races, allocation failure, and
unexpected I/O abort. Bundles, pulls, imports, and cache materialization remain
chunk-authoritative. The user-facing CLI has no trust flag.

The durable contract lives in `docs/memory.md`, `docs/spore-format.md`,
`docs/fanout.md`, and `SECURITY.md`.

## Restore Planning Module

`src/ram_restore.zig` is the single product restore-planning module. It loads or
accepts the manifest memory description, validates the vCPU contract, selects
proof-gated local backing or verified chunks, owns any opened backing fd, and
hands KVM or HVF one resolved strategy. Product run-from, attach, and named
monitor restore use that module instead of independently combining a nullable
backing fd with a chunk restore mode.

Backend-specific lazy fault handling remains inside KVM and HVF. The shared
strategy makes fresh RAM, local backing, eager chunks, and lazy chunks mutually
exclusive before backend startup.

## Release Evidence

Exact candidate `0ce47154dcb777cca8ce7fbcecdb7deea172a6d6` closes the native
correctness and evidence gates without retries or waivers:

- The complete exact-head graph passed 18/18 steps: 1,681/1,694 tests passed,
  13 skipped, and none failed. Internal tests passed 781/786, build tests passed
  874/882, the durable crash suite passed 2/2, and the C smoke test passed.
- HVF restored an old unequal-counter two-vCPU manifest through ten valid-local
  restores with ten repeated execs each (100/100). Every row selected
  `local_backing` with `proof_valid` and `memory_ms=0`. Five deliberate eager
  restores with five repeated execs each passed 25/25, selected `eager_chunks`
  with `key_unavailable`, and reported 115-116 ms of memory materialization.
- The HVF cross-vCPU timer oracle passed 20,000 affinity alternations before
  save, while continuing after save, after the first restore, and after a
  second save and restore. CNTVCT and `CLOCK_MONOTONIC` never stepped backward,
  newly saved two-vCPU anchors were identical, and retained output contained no
  RCU stall or soft-lockup report.
- The checked-in KVM matrix passed all five rows and five repeated execs for
  current one- and two-vCPU local backing and deliberate eager fallback. Local
  restores took 70.7-71.7 ms with 30-31 ms wait time and `memory_ms=0`; eager
  restores took 613.2-634.8 ms with 572-593 ms wait time and 533-544 ms of
  memory materialization.
- Historical baseline/current lanes, unsupported schema-v1 local and
  missing-key behavior, real ext4 fs-verity schema-v2 plus fan-out, tmpfs
  schema-v1, and cross-filesystem eager fallback all passed. Cross-filesystem
  fallback selected `no_backing`, took 611.8-612.7 ms, and materialized memory
  in 533-538 ms. The ext4 run enabled and measured fs-verity through the owned
  backing fd, restored its exact final mode, and published the proof only after
  identity revalidation.

The retained public-safe evidence digests are KVM `evidence.json`
`b1f835d855cb584c5835fa06e9a3e0ee7bb1c64b937a5bd30740dc5b135b82d7`,
full-suite transcript
`7d6c395ff495eb5d2f3f261f367ee24719478dd0a62d243b00e623aad1dab492`, HVF
valid-local JSONL
`cd5a96fe7a3bf1f9688b64b50041a136d6643ecad4be48558a47485f24cb40dc`, and HVF
eager JSONL
`8cf5b32328f4efc72e70e1aff7cd233a89945e64f49162c0913f78dc86ff63a6`.

The release harness and proof telemetry are implemented in this follow-up. The
harness fixes the matrix at 1024 MiB with five complete rows and five repeated
execs per lane. It validates current one- and two-vCPU local backing and
deliberate eager fallback on KVM and HVF, keeps the v0.12.0 historical lane
separate, pins every historical release input and each managed-kernel artifact,
records the task-owned kernel cache, and enforces named cleanup through parser
failure and signals. Linux additionally exercises schema-v2 fs-verity,
schema-v1 tmpfs, fan-out, and cross-filesystem fallback. Its Linux release lane
ignores the general benchmark scratch, requires the selected scratch to be
ext4, and enables and measures a disposable fs-verity file before parent
capture. The Linux job selects the host-provisioned, agent-writable
`/var/tmp/sporevm-named-restore-verity` task scratch root rather than the
checkout or general benchmark scratch. Earlier candidate review and native
evidence predated the HVF counter finding; the exact-head evidence above
supersedes those runs and closes the corrected KVM/HVF release gate.

## Key Learnings From Pressure-Testing

- Repeated HVF exec timeouts were not lost MMIO completions. Exact QueueNotify
  tracing showed the host consumed each console descriptor and advanced the
  guest PC; retained guest output identified cross-CPU virtual-time skew through
  the RCU stall report.
- The single-vCPU HVF timer re-anchor could not be applied independently to
  multiple vCPUs. One machine counter plus modular per-vCPU deadline
  translation is the smallest architecture-correct model.
- Runtime diagnostics must describe configured state. An unconditional default
  console path hid the useful output while claiming a file existed, and saved
  lifecycle paths cannot become fresh host write authority during restore.

## Done When

- [x] Exact-head KVM and HVF evidence passes correctness before performance,
  with no retry or waiver for repeated exec.
- [x] Linux fs-verity and unsupported-filesystem evidence is recorded in the
  active plan and retained release artifacts.
- [x] Unsupported filesystems continue to use v1 provenance proofs or verified
  chunks without a user-facing mode.

## Non-Goals

- No database or daemon for local backing provenance.
- No full-file hashing of `ram.backing` in hot restore paths.
- No portable trust claim for `ram.backing`.
