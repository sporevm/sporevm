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

The current branch uses a direct merged tar tree by default. It no longer feeds
the native writer from the host staging directory. Regular files are recorded
as content sources and emitted block-by-block from seekable tar layer offsets or
spooled gzip layers. Set `SPOREVM_EXT4_WRITER=external` to use the old
e2fsprogs path.

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

The native writer is the default. The external writer remains available with
`SPOREVM_EXT4_WRITER=external`. Unknown writer names return
`UnsupportedExt4Writer`; there is no silent fallback from a requested writer
path.

## Current State

Landed in this branch:

- `src/rootfs/ext4_writer.zig` can emit deterministic, fsck-clean ext4 images
  for synthetic trees and merged layer trees.
- `src/rootfs/tar.zig` can build an in-memory merged tree from supported layer
  tars, including whiteouts, hardlinks, symlink traversal checks, ownership, and
  bounded `security.capability` xattrs.
- `materializeRootFS` defaults to the native emitter; `SPOREVM_EXT4_WRITER`
  remains as an internal selector and `external` keeps the e2fsprogs path
  available as an escape hatch.
- Native materialization keeps the existing digest-cache and metadata behavior
  and computes BLAKE3 inline during emission.
- Regular file contents in the native path are replayed from source locations:
  plain tar layers use payload offsets directly, gzip layers spool once into the
  materialization temp directory, and the ext4 writer reads source-backed data
  blocks during final image emission.
- The native planner/metadata-emitter has an integrated fuzz target covering
  mixed entry trees, parent synthesis, hardlinks, source-backed file blocks,
  symlinks, device nodes, special files, xattrs, block assignment, and metadata
  emission.
- `scripts/benchmark-rootfs-writers.py` compares native and external writer
  conversion phases from the existing `SPOREVM_ROOTFS_BUILD_PROFILE=1` output
  and writes JSON plus a Markdown phase table.
- Guest boot/read-back smokes pass for a native-built Alpine rootfs and a
  native-built Buildkite agent rootfs.
- A Buildkite agent image conversion phase table is recorded below; native is
  correct and dependency-free but currently slower in the emit phase on this
  macOS run, so the external fallback remains documented.
- Focused tests cover deterministic output, multi-group images, double-indirect
  files, hardlink ordering, merged-tree whiteouts/hardlinks, explicit writer
  selection, gzip spooling for merged trees, staging-vs-native layer semantics,
  native-vs-external debugfs read-back for materialized images, repeated native
  determinism, and a small `materializeRootFS` native import.
- A merged-tree tar fuzz target runs alongside the existing staging tar fuzz
  target.

Follow-up after the default flip:

- Native writer throughput optimization; the default flip keeps the external
  e2fsprogs path available while `native_ext4_emit` is tuned.

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

Status: complete in this branch.

The writer selector exists and native selection bypasses staging. A focused
debugfs read-back test now materializes the same layer through external and
native writers, compares guest-visible file contents, and verifies repeated
native imports produce the same BLAKE3.

Definition of done:

- Small OCI and rootfs-tar fixtures materialize through the direct native path.
- Native output is fsck-clean and semantically equal to the external output.
- Two native imports of the same input produce the same BLAKE3.

### Slice 4: Evidence And Default Flip

Status: complete in this branch.

Collect enough evidence to make native the default and keep the external path
as an escape hatch for at least one release.

Definition of done:

- Guest boot/read-back smoke passes on representative images.
- Buildkite image conversion phase table is recorded here.
- Integrated fuzz targets run in rootfs tests with no outstanding findings.
- The default flips and the fallback is documented for release notes.

Evidence collected on 2026-07-08 from this branch on macOS arm64/HVF:

- Default native guest smoke:
  `scripts/smoke-run-oci-rootfs.sh --no-build --image public.ecr.aws/docker/library/alpine:3.20 -- /bin/echo native-rootfs-smoke`
  built `public.ecr.aws/docker/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d`
  and printed `native-rootfs-smoke`.
- Native benchmark-image boot:
  `zig-out/bin/spore run --rootfs zig-cache/rootfs-writer-benchmarks/rootfs-native.ext4 -- /usr/local/bin/node -v`
  printed `v22.23.1`.
- Native Buildkite agent image boot:
  `zig-out/bin/spore run --rootfs zig-cache/rootfs-writer-benchmarks-buildkite-agent/rootfs-native.ext4 -- /bin/sh -lc 'buildkite-agent --version >/tmp/agent-version 2>&1 || true; cat /tmp/agent-version; echo buildkite-agent-rootfs-ok'`
  printed `buildkite-agent version 3.131.0+13069.88329801c4c284e44fd849ce8b0a2e74179ba24d`
  and `buildkite-agent-rootfs-ok`.

Buildkite agent rootfs conversion table:

| Writer | Status | Total | Conversion phases | Rootfs size | BLAKE3 prefix |
| --- | ---: | ---: | ---: | ---: | --- |
| `external` | 0 | 59.86s | 17.76s | 620756992 | `67a866b5de6680c8` |
| `native` | 0 | 61.74s | 29.42s | 620756992 | `9828e4be2475afb2` |

| Phase | External | Native |
| --- | ---: | ---: |
| `tree_merge` | - | 8.37s |
| `layer_extract_staging` | 12.36s | - |
| `rootfs_tree_finalize` | 13ms | 0ms |
| `host_metadata_normalize` | 143ms | - |
| `ext4_size_scan` | 34ms | 1ms |
| `ext4_create_empty` | 0ms | - |
| `mkfs_ext4` | 785ms | - |
| `debugfs_finalize` | 575ms | - |
| `rootfs_blake3` | 3.85s | - |
| `native_ext4_emit` | - | 21.05s |

## Verification

- `zig test src/rootfs.zig --test-filter "native ext4 writer"`.
- Full rootfs tests: `zig test src/rootfs.zig`.
- Repo validation: `mise run test`, `mise run build`, `git diff --check`.
- `e2fsck -f -n` on emitted test images when e2fsprogs is available.
- Later slices: guest boot/read-back and `SPOREVM_ROOTFS_BUILD_PROFILE=1`
  benchmarks with `scripts/benchmark-rootfs-writers.py`.

## Resolved Decisions

- The first native profile is deliberately simpler than mke2fs output and does
  not attempt byte-identical output with the external serializer.
- `SPOREVM_EXT4_WRITER` remains an internal fallback selector, not a durable
  user interface yet.
- The staging-tree bridge is acceptable only as an emitter/integration slice;
  it does not satisfy the direct tar-to-ext4 goal by itself.

## Deferred Work

- Improve source-backed native emission throughput; the 2026-07-08 Buildkite
  agent benchmark showed `native_ext4_emit` slower than the external
  extract/mkfs/debugfs/hash sequence on macOS.
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
