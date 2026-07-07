---
status: active
last_reviewed: 2026-07-08
spec_refs:
  - docs/filesystem.md
  - docs/rootfs.md
  - SECURITY.md
  - src/rootfs/ext4.zig
  - src/rootfs/tar.zig
  - src/rootfs/ext4_writer.zig
related_plans:
  - docs/plans/rootfs-conversion-optimization.md
  - docs/plans/spore-build.md
---

# Native Zig Tar-To-Ext4 Writer

## Summary

Replace the external `mke2fs -d` plus `debugfs -w` rootfs materialization path
with a native Zig writer that creates a fresh ext4 image, sets deterministic
metadata itself, and computes the rootfs BLAKE3 while emitting image bytes.

The intended end state is a direct layer-to-ext4 pipeline: parse each layer,
merge OCI tar semantics into an in-memory tree, plan the image, then stream the
image bytes without depending on host e2fsprogs behavior. The rollout remains
fail-closed: the external path stays the default until the native path has
semantic, boot, fuzz, and benchmark evidence.

## Problem

`materializeRootFS` currently stages layers into a host directory, invokes
`mke2fs -d`, runs `debugfs` to repair deterministic metadata that the host tree
cannot represent directly, then reads the entire image again for BLAKE3. That
pipeline is slow on large images and depends on the installed e2fsprogs version
for details of the emitted filesystem.

The native writer is meant to remove the host-tool dependency and collapse the
serializer/hash passes while preserving the existing cache and metadata
contracts.

## Goals

- Produce fsck-clean ext4 images without runtime e2fsprogs.
- Keep output deterministic for identical layer inputs and manifest digest.
- Preserve digest-cache, metadata sidecar, and `rootfs.storage` behavior.
- Preserve current tar semantics: path safety, whiteouts, opaque directories,
  modes, ownership, symlinks, hardlinks, and bounded `security.capability`.
- Keep the external writer available until the native path has enough evidence
  to become the default.

## Non-Goals

- No general ext4 library. This is write-only and create-only.
- No journal, `metadata_csum`, `orphan_file`, or `dir_index` in the first
  native profile.
- No guest-visible rootfs format change.
- No default flip before semantic comparison, guest boot, fuzz, and benchmark
  evidence exist.

## Target Model

The final pipeline has two logical passes:

1. Parse and merge layer tar metadata into an in-memory tree. Regular files
   record content identity and location instead of being copied into a staging
   directory.
2. Plan and emit a fixed ext4 layout while hashing the emitted bytes inline.

The current branch uses a direct merged tar tree when
`SPOREVM_EXT4_WRITER=native` is set. It no longer feeds the native writer from
the host staging directory. Regular files are recorded as content sources and
emitted block-by-block from seekable tar layer offsets or spooled gzip layers.

## Ext4 Profile

- 4096-byte blocks, 256-byte inodes, sparse superblocks, filetype entries,
  external xattr blocks, no journal, no checksums, no extents yet.
- Block-mapped files support direct, single-indirect, and double-indirect data
  blocks. Larger files fail closed until triple-indirect or extents are added.
- Symlinks up to 60 bytes are stored inline; longer symlinks use data blocks.
- Directories are linear and deterministic by path sort.
- Device nodes, FIFOs, sockets, uid/gid high bits, hardlinks, and
  `security.capability` xattrs are represented in the synthetic emitter API.

## Safety Model

OCI layers and local rootfs tars are attacker-influenced input. New parsing or
tree-merge logic must fail closed and carry fuzz coverage in the same slice.
The writer itself re-checks path safety, inode counts, image size, link counts,
xattr bounds, and unsupported file sizes before writing an image.

The external writer remains available with `SPOREVM_EXT4_WRITER=external` or an
unset variable. Unknown writer names return `UnsupportedExt4Writer`; there is
no silent fallback from a requested native path.

## Current State

Landed in this branch:

- `src/rootfs/ext4_writer.zig` can emit deterministic, fsck-clean ext4 images
  for synthetic trees and merged layer trees.
- `src/rootfs/tar.zig` can build an in-memory merged tree from supported layer
  tars, including whiteouts, hardlinks, symlink traversal checks, ownership, and
  bounded `security.capability` xattrs.
- `materializeRootFS` has an internal writer selector:
  `SPOREVM_EXT4_WRITER=native` selects the native emitter; unset or `external`
  keeps the e2fsprogs path.
- Native materialization keeps the existing digest-cache and metadata behavior
  and computes BLAKE3 inline during emission.
- Regular file contents in the native path are replayed from source locations:
  plain tar layers use payload offsets directly, gzip layers spool once into the
  materialization temp directory, and the ext4 writer reads source-backed data
  blocks during final image emission.
- Focused tests cover deterministic output, multi-group images, double-indirect
  files, hardlink ordering, merged-tree whiteouts/hardlinks, explicit writer
  selection, gzip spooling for merged trees, staging-vs-native layer semantics,
  and a small `materializeRootFS` native import.
- A merged-tree tar fuzz target runs alongside the existing staging tar fuzz
  target.

Still incomplete:

- Guest boot/read-back validation and native-vs-external semantic comparison.
- Integrated planner/emitter fuzz targets beyond the merged-tree tar parser.
- Buildkite-image benchmark evidence and default flip.

## Delivery Strategy

### Slice 1: Ext4 Emitter Core

Status: active in this branch.

Definition of done:

- Synthetic trees emit fsck-clean images.
- Duplicate emits are byte-identical and inline BLAKE3 matches a post-hoc
  `blake3File`.
- Planner arithmetic and hardlink/link-count behavior fail closed.
- Coverage includes block-group boundaries and large regular files.

### Slice 2: Merged Tree From Layer Tars

Status: complete in this branch.

`src/rootfs/tar.zig` now has a native metadata tree builder with source-backed
regular files. A staging-vs-native fixture covers ownership, xattrs, whiteouts,
hardlinks, symlinks, implicit dirs, and regular file content; the merged-tree
fuzz target covers adversarial tar metadata.

Definition of done:

- Existing tar whiteout, path-safety, ownership, hardlink, and xattr tests pass.
- Fixture layer stacks produce semantically identical staging and in-memory
  trees.
- Fuzz coverage lands for tree merge shapes and adversarial tar metadata.

### Slice 3: Wire Direct Native Writer Into `materializeRootFS`

Status: partial.

The writer selector exists and native selection bypasses staging. This slice is
not complete until native output has semantic comparison and guest read-back
evidence.

Definition of done:

- Small OCI and rootfs-tar fixtures materialize through the direct native path.
- Native output is fsck-clean and semantically equal to the external output.
- Two native imports of the same input produce the same BLAKE3.

### Slice 4: Evidence And Default Flip

Status: pending.

Collect enough evidence to make native the default and keep the external path
as an escape hatch for at least one release.

Definition of done:

- Guest boot/read-back smoke passes on representative images.
- Buildkite image conversion phase table is recorded here.
- Integrated fuzz targets run in CI with no outstanding findings.
- The default flips and the fallback is documented for release notes.

## Verification

- `zig test src/rootfs.zig --test-filter "native ext4 writer"`.
- Full rootfs tests: `zig test src/rootfs.zig`.
- Repo validation: `mise run test`, `mise run build`, `git diff --check`.
- `e2fsck -f -n` on emitted test images when e2fsprogs is available.
- Later slices: native-vs-external semantic comparison, guest boot/read-back,
  integrated fuzz, and `SPOREVM_ROOTFS_BUILD_PROFILE=1` benchmarks.

## Resolved Decisions

- The first native profile is deliberately simpler than mke2fs output and does
  not attempt byte-identical output with the external serializer.
- `SPOREVM_EXT4_WRITER` is an internal rollout selector, not a durable user
  interface yet.
- The staging-tree bridge is acceptable only as an emitter/integration slice;
  it does not satisfy the direct tar-to-ext4 goal by itself.

## Deferred Work

- Deterministic extents or triple-indirect support for very large files.
- Deterministic `dir_index` if large-directory guest lookup performance needs
  it.
- `metadata_csum` if a future kernel policy requires it.
- Parallel layer-content streaming if direct native emission is I/O-bound.

## Key Learnings From Pressure-Testing

The smallest useful slice is the create-only emitter plus an internal
`materializeRootFS` selector. It proves the filesystem bytes, cache contract,
and inline hash path before taking on the higher-risk tar merge refactor.

The main remaining risk is semantic drift between native tree merging and the
existing staging applier. Slice 2 must either share the merge oracle directly or
add strong differential tests that make drift visible before the default flips.
