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
  - docs/plans/unified-chunk-disk.md
---

# Native Zig Tar-To-Ext4 Writer

## Summary

Replace the external `mke2fs -d` plus `debugfs -w` rootfs materialization
pipeline with a native Zig writer that serializes a merged OCI layer tree into
a fresh ext4 image, sets deterministic metadata itself, and computes the rootfs
BLAKE3 inline as image bytes are emitted.

This writer is now scoped as the U4 import producer for
[Unified Chunk-Mapped Disk](unified-chunk-disk.md): today it emits the flat
ext4 artifact and rootfs BLAKE3; the next storage slice extends the same
sequential emission loop to produce 64 KiB chunk digests and a
`spore-disk-index-v1` inline. It stays create-only. Incremental/in-place
mutation and snapshot persistence belong to U3's chunk sealer.

## Problem

The external materialization path stages layers into a host directory, invokes
e2fsprogs to create the ext4 image, runs `debugfs` to repair deterministic
metadata that the host tree cannot represent, then reads the image again for
BLAKE3 and rootfs CAS chunking.

That pipeline has three costs:

- It depends on host e2fsprogs behavior for bytes that are supposed to be
  deterministic.
- It pays for a host staging tree even though the guest only consumes the final
  block device.
- It cannot emit the future U4 chunk index inline because the serializer is an
  opaque external process.

The native writer removes the runtime e2fsprogs dependency and makes the
serializer the point where flat bytes, rootfs digest, and future chunk-index
identity are produced together.

## Goals

- Produce deterministic, fsck-clean ext4 images without runtime e2fsprogs.
- Preserve OCI layer semantics: path safety, whiteouts, opaque directories,
  modes, ownership, symlinks, hardlinks, and bounded `security.capability`
  xattrs.
- Keep the existing digest-cache, metadata sidecar, and rootfs storage behavior
  until U4 replaces post-hoc rootfs CAS chunking.
- Keep the writer loop sequential and content-source backed so a second
  per-64KiB hasher can be added without another full-image pass.
- Keep the external writer available with `SPOREVM_EXT4_WRITER=external`.

## Non-Goals

- No general ext4 library. This is write-only and create-only: no reading,
  appending, or modifying existing images.
- No journal, `metadata_csum`, `orphan_file`, `dir_index`, extents, or
  triple-indirect support in the first native profile.
- No new guest-visible rootfs format. The VM still sees one virtio-blk ext4
  disk.
- No investment in `rootfs_cas_preload`, storage-upgrade paths, or
  chunked-to-flat assembly. U4 deletes that post-hoc path and replaces it with
  inline `spore-disk-index-v1` emission.

## Target Model

The native path has two passes:

1. Parse layer tar metadata into an in-memory merged tree. Regular files record
   content source identity and byte ranges instead of being copied into a
   staging directory. Plain tar layers are seekable; gzip layers spool once into
   the materialization temp dir.
2. Plan and emit a fixed ext4 layout while hashing emitted bytes inline. The
   same loop is intentionally shaped to add U4 chunk hashing:
   rootfs BLAKE3 over all bytes today, then per-64KiB chunk BLAKE3 plus index
   construction next.

The current profile uses 4096-byte blocks, 256-byte inodes, sparse
superblocks, filetype directory entries, external xattr blocks, inline symlinks
up to 60 bytes, and block-mapped regular files with direct, single-indirect,
and double-indirect blocks. Larger files fail closed until extents or
triple-indirect blocks are added.

## Safety Model

OCI layers and local rootfs tars are attacker-influenced input. The merged-tree
path rejects unsafe paths, symlink traversal, invalid hardlinks, unsupported
xattrs, and size/count limit violations. The writer re-checks path safety,
inode counts, image size, link counts, xattr bounds, and unsupported file sizes
before writing.

The default native flip is a flag-day cache break: `builder_version` is
`sporevm-rootfs-v4`, so old `v3` rootfs cache entries are abandoned and rebuilt.
The by-digest cache is not split by writer. Rootfs metadata records the selected
writer, and cache validation rejects a metadata/artifact pair produced by the
other writer so `SPOREVM_EXT4_WRITER=external` remains an effective escape
hatch.

## Current State

Implemented in this branch:

| Area | Status | Evidence |
| --- | --- | --- |
| Synthetic ext4 emission | Done | Deterministic images, multi-group images, hardlinks, device/special files, xattrs, large double-indirect files, and fsck checks in `src/rootfs/ext4_writer.zig` tests. |
| Merged tree from layer tars | Done | `src/rootfs/tar.zig` builds source-backed merged trees and compares them with staging semantics for whiteouts, hardlinks, symlinks, ownership, xattrs, implicit dirs, and content. |
| Native materialization wiring | Done | `materializeRootFS` selects native by default, external by `SPOREVM_EXT4_WRITER=external`, and writes `ext4_writer` into rootfs metadata. |
| Native/external semantic parity | Done | Focused debugfs read-back test materializes the same layer through both writers and compares guest-visible file contents; repeated native output has the same BLAKE3. |
| Determinism | Done | Duplicate native emits and repeated native materialization produce stable BLAKE3 for the tested inputs. |
| Fuzz coverage | Done | Existing tar fuzzing is extended with merged-tree fuzzing, and the native planner/metadata emitter has an integrated fuzz target. |
| Cache identity | Done | Builder version bumped to `sporevm-rootfs-v4`; cache validation includes the selected writer metadata without hashing writer selection into the cache key. |
| Guest boot smoke | Done | Native-default OCI smoke built and booted Alpine with `builder_version: sporevm-rootfs-v4`, `ext4_writer: native`, and guest output `native-rootfs-smoke`. |
| Writer benchmark | Done | Post-v4 native vs external phase table recorded below; native output is byte-identical to the pre-v4 run and the emit-throughput gap is a documented follow-up, not a flip blocker. |

## Rollout Gates

Before merge:

- Native-default OCI boot smoke passes and is recorded here.
- Focused native/external parity, cache, and TLS tests pass after the v4
  re-scope.
- Full `zig test src/rootfs.zig`, `mise run test`, and `mise run build` pass.

Before removing the external fallback:

- U4 inline chunk-index emission exists, replacing the post-hoc
  `rootfs_cas_preload` full-image re-read.
- Native writer throughput is acceptable on representative large images.
- The first profile either supports extents/triple-indirect blocks or the
  `UnsupportedExt4FileSize` fallback remains documented and tested.

## Boot Evidence

Recorded on 2026-07-08 in this worktree:

```bash
tmp_cache="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-native-smoke-cache.XXXXXX")" &&
env -u SPOREVM_EXT4_WRITER SPOREVM_ROOTFS_CACHE_DIR="$tmp_cache" \
  scripts/smoke-run-oci-rootfs.sh --no-build \
  --image public.ecr.aws/docker/library/alpine:3.20 \
  -- /bin/echo native-rootfs-smoke
```

Observed:

- Metadata recorded `builder_version: sporevm-rootfs-v4`.
- Metadata recorded `ext4_writer: native`.
- Resolved image:
  `public.ecr.aws/docker/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d`.
- Rootfs BLAKE3:
  `56f376dcf47aebd6470acf731f90ed2883537d609417adcf86186db62d88844c`.
- Guest output: `native-rootfs-smoke`.

## Benchmark Evidence

Recorded on 2026-07-08 in this worktree after the v4/default-flip diff, using
`scripts/benchmark-rootfs-writers.py --no-build --image docker.io/buildkite/agent:3`
on macOS arm64/HVF:

| Writer | Status | Total | Conversion phases | Rootfs size | BLAKE3 prefix |
| --- | ---: | ---: | ---: | ---: | --- |
| `external` | 0 | 50.93s | 16.98s | 620756992 | `67a866b5de6680c8` |
| `native` | 0 | 61.77s | 29.48s | 620756992 | `9828e4be2475afb2` |

| Phase | External | Native |
| --- | ---: | ---: |
| `tree_merge` | - | 8.34s |
| `layer_extract_staging` | 11.94s | - |
| `rootfs_tree_finalize` | 13ms | 0ms |
| `host_metadata_normalize` | 126ms | - |
| `ext4_size_scan` | 35ms | 1ms |
| `ext4_create_empty` | 1ms | - |
| `mkfs_ext4` | 509ms | - |
| `debugfs_finalize` | 546ms | - |
| `rootfs_blake3` | 3.82s | - |
| `native_ext4_emit` | - | 21.14s |

Native BLAKE3 matches the pre-v4 run exactly, confirming the review-response
diff did not change emitted bytes. Native conversion is currently ~12.5s slower
than external on this image, dominated by `native_ext4_emit`; the default flip
proceeds on correctness, determinism, and dependency-freedom, with emit
batching tracked under Known Limits as the throughput follow-up.

Note: the v5 symlink-boundary fix below changes emitted bytes for images
containing 60-byte symlink targets (including `buildkite/agent:3`), so the
BLAKE3 prefixes above no longer reproduce on v5.

### OSS Comparison

Recorded on 2026-07-08 with
`scripts/benchmark-ext4-writer-comparison.py --tar <docker export of buildkite/agent:3>`
(312 MiB flattened tar, macOS arm64), after the symlink-boundary fix:

| Tool | Wall | Conversion | Output size | e2fsck -fn |
| --- | ---: | ---: | ---: | --- |
| `spore (native)` | 23.47s | 20.33s | 592 MiB | clean |
| `spore (external)` | 11.37s | 4.93s | 592 MiB | clean |
| `tar2ext4` (hcsshim v0.14.1) | 173ms | 173ms | 323 MiB | exit 4 (bitmap padding nit only) |

The single-layer flat-tar path removes multi-layer merge cost, which is why
external conversion is faster here than in the table above. The headline is
tar2ext4: compactext4 converts the same content roughly 100x faster than
`native_ext4_emit` by buffering and writing sequentially, versus our one
positional 4 KiB write per data block. That bounds the emit-batching follow-up:
sub-second conversion is achievable for this size class on this hardware.
This comparison also caught the 60-byte symlink bug — the harness runs
`e2fsck -fn` on every output and stays useful as a cross-implementation
correctness check.

## Next: Inline Chunk Index Emission For U4

The next real storage slice is not more rootfs CAS plumbing. It is extending the
native writer emission loop so every 64 KiB of logical image bytes also feeds a
chunk hasher and writes/records the corresponding CAS object for
`spore-disk-index-v1`.

Keep the current writer loop friendly to that change:

- Preserve the sequential block walk in `writeImage`.
- Avoid adding new callers that depend on the current `Result{ blake3, size }`
  shape as the durable writer API.
- Do not expand `ensureImageRootfsStorage`, storage upgrade, or chunked-to-flat
  assembly paths; those are deleted by U4.

## Known Limits

- A single regular file larger than direct + single-indirect + double-indirect
  coverage, roughly 4 GiB with 4 KiB blocks, fails closed with
  `UnsupportedExt4FileSize`. Use `SPOREVM_EXT4_WRITER=external` for images with
  larger files until extents or triple-indirect support lands.
- Large-directory lookup is linear because `dir_index` is not emitted.
- Native emission is currently one positional read/write per 4 KiB data block;
  batching is the likely throughput follow-up if benchmarks show emit-bound
  behavior.

## Related Implementations

- [hcsshim tar2ext4](https://github.com/microsoft/hcsshim/tree/main/ext4/tar2ext4)
  / [compactext4](https://github.com/microsoft/hcsshim/tree/main/ext4/internal/compactext4)
  (Go, MIT): the closest production analog — streams a tar directly into a
  compact ext4 image for LCOW. Useful reference for extent emission and
  streamed layout when we lift the 4 GiB file limit. Its sibling
  [dmverity](https://github.com/microsoft/hcsshim/tree/main/ext4/dmverity)
  package is relevant to future integrity work.
- [e2fsprogs / libext2fs](https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git)
  (GPL/LGPL): the canonical implementation. `mke2fs -d` backs the external
  writer path, and `e2fsck` is the correctness oracle in the writer's tests —
  reference behaviour, not borrowed code.
- [lwext4](https://github.com/gkostka/lwext4) (mostly BSD): a readable
  standalone extents implementation. Note `ext4_extents.c` is GPL-licensed —
  reference only, do not port code from it.
