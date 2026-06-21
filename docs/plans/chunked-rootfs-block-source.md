---
status: superseded
last_reviewed: 2026-06-22
superseded_by: docs/filesystem.md
spec_refs:
  - docs/filesystem.md
  - docs/rootfs.md
  - docs/spore-format.md
---

# Chunked Rootfs Block Source Plan

This implementation plan is superseded by
[`docs/filesystem.md`](../filesystem.md). The plan landed through the default
producer path: `spore rootfs build` writes chunked rootfs CAS storage, and
`spore run --image ... --capture` records `rootfs.storage` without a manual
preload step.

Use `docs/filesystem.md` for the current `CasBlockSource`,
`rootfs.storage`, distribution, cache, and verification contract. The old
env-gated local-index spike has been removed, so manifest storage is the only
CAS runtime selector. The manifest-attached benchmark remains available as
`mise run benchmark:manifest-rootfs-cas`.
