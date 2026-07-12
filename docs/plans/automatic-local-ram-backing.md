---
status: active
last_reviewed: 2026-07-12
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

## Remaining Work

- Run the release matrix at its exact committed head on Linux ARM64/KVM and an
  unsandboxed macOS ARM64/HVF host. Retain the normalized evidence JSON and the
  per-lane JSONL for review.
- Record Linux schema-v2 fs-verity proof-write cost, parent and fan-out
  validation cost, five-row tmpfs schema-v1 behavior, and five-row
  cross-filesystem chunk fallback from that run.
- Confirm on the provisioned ext4 runner that `FS_IOC_ENABLE_VERITY` succeeds
  through the existing `O_RDONLY` backing fd after temporary owner-write is
  added, and that the final backing mode is restored before proof publication.

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
checkout or general benchmark scratch. Candidate ship-risk, maintainability,
documentation, and draft PR-description review is complete; exact native
evidence remains the release gate.

## Done When

- Exact-head KVM and HVF evidence passes correctness before performance, with
  no retry or waiver for repeated exec.
- Linux fs-verity and unsupported-filesystem evidence is recorded in the PR or
  a short durable docs note.
- Unsupported filesystems continue to use v1 provenance proofs or verified
  chunks without a user-facing mode.

## Non-Goals

- No database or daemon for local backing provenance.
- No full-file hashing of `ram.backing` in hot restore paths.
- No portable trust claim for `ram.backing`.
