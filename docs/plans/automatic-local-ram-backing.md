---
status: active
last_reviewed: 2026-07-06
spec_refs:
  - docs/memory.md
  - docs/spore-format.md
  - docs/fanout.md
  - SECURITY.md
  - src/attach.zig
  - src/fanout.zig
  - src/spore.zig
---

# Automatic Local RAM Backing Follow-Up

## Current Contract

The implementation has landed. Product restore paths automatically map
same-host `ram.backing` only when `ram.backing.proof` validates against the
manifest memory fingerprint, opened file identity, backing metadata, and the
host-local runtime key. Missing, stale, foreign, symlinked, corrupt, or
mismatched proofs fall back to verified chunks.

`spore fork` hard-links a proof-valid parent backing file into children and
writes child-local proofs. Bundles, pulls, imports, and cache materialization
remain chunk-authoritative. The user-facing CLI has no trust flag.

The durable contract lives in `docs/memory.md`, `docs/spore-format.md`,
`docs/fanout.md`, and `SECURITY.md`.

## Remaining Work

- Collect Linux fs-verity benchmark evidence for schema v2 proofs: proof write
  cost, resume/fan-out validation cost, and fallback behavior on unsupported
  filesystems.
- Keep restore-source reporting (`local_backing` versus `chunks`) in product
  smokes so fast-path regressions are visible.

## Done When

- Linux fs-verity evidence is recorded in the PR or a short durable docs note.
- Unsupported filesystems continue to use v1 provenance proofs or verified
  chunks without a user-facing mode.

## Non-Goals

- No database or daemon for local backing provenance.
- No full-file hashing of `ram.backing` in hot restore paths.
- No portable trust claim for `ram.backing`.
