---
status: superseded
last_reviewed: 2026-06-22
superseded_by: docs/filesystem.md
spec_refs:
  - docs/filesystem.md
  - docs/rootfs.md
  - docs/spore-format.md
---

# Immutable Rootfs Resume Plan

This implementation plan is superseded by
[`docs/filesystem.md`](../filesystem.md). The landed contract is now broader
than immutable exact-rootfs resume: image-created spores record an immutable
ext4 artifact plus manifest-attached chunked rootfs storage by default, and
older exact-rootfs spores keep the verified fd-backed compatibility path.

Use `docs/filesystem.md` for the current root disk, rootfs CAS, writable layer,
bundle, cache, and verification contract. Use `docs/rootfs.md` for CLI-oriented
rootfs usage.
