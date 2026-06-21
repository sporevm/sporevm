---
status: superseded
last_reviewed: 2026-06-22
superseded_by: docs/filesystem.md
spec_refs:
  - docs/filesystem.md
  - docs/spore-format.md
---

# Writable Disk Layer Plan

This implementation plan is superseded by
[`docs/filesystem.md`](../filesystem.md). The rootfs-bound writable disk target
has landed: active writes use a local COW head, capture seals dirty blocks into
`disk-layer-v0` indexes and BLAKE3 disk objects, forked children share sealed
parent layers, and bundles/pulls carry the referenced disk layer data.

Use `docs/filesystem.md` for the current root disk and writable layer contract.
File-content indexes, broader cluster-size tuning, and lazy remote disk reads
remain deferred until measurements justify them.
