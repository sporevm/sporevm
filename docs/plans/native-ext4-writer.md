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
a fresh ext4 image, sets deterministic metadata itself, and emits the rootfs
CAS index inline as image bytes are written.

This writer is now scoped as the U4 import producer for
[Unified Chunk-Mapped Disk](unified-chunk-disk.md): for chunked rootfs storage
it emits the flat ext4 artifact, 64 KiB CAS objects, and the rootfs
`spore-disk-index-v1` in the same sequential emission loop. The external
writer remains as an escape hatch and still uses the post-hoc full-image
preload fallback. The native writer stays create-only. Incremental/in-place
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
- It cannot emit the rootfs chunk index inline because the serializer is an
  opaque external process.

The native writer removes the runtime e2fsprogs dependency and makes the
serializer the point where flat bytes, rootfs objects, and rootfs index
identity are produced together.

## Goals

- Produce deterministic, fsck-clean ext4 images without runtime e2fsprogs.
- Preserve OCI layer semantics: path safety, whiteouts, opaque directories,
  modes, ownership, symlinks, hardlinks, and bounded `security.capability`
  xattrs.
- Keep the existing metadata sidecar and rootfs storage behavior while making
  native chunked imports produce `H(index)` inline.
- Keep the writer loop sequential and content-source backed so flat bytes,
  64 KiB chunk objects, and index identity are produced without another
  full-image pass.
- Keep the external writer available with `SPOREVM_EXT4_WRITER=external`.

## Non-Goals

- No general ext4 library. This is write-only and create-only: no reading,
  appending, or modifying existing images.
- No journal, `metadata_csum`, `orphan_file`, `dir_index`, extents, or
  triple-indirect support in the first native profile.
- No new guest-visible rootfs format. The VM still sees one virtio-blk ext4
  disk.
- No investment in expanding `rootfs_cas_preload`, storage-upgrade paths, or
  chunked-to-flat assembly. `rootfs_cas_preload` remains only as the external
  writer fallback.

## Target Model

The native path has two passes:

1. Parse layer tar metadata into an in-memory merged tree. Regular files record
   content source identity and byte ranges instead of being copied into a
   staging directory. Plain tar layers are seekable; gzip layers spool once into
   the materialization temp dir.
2. Plan and emit a fixed ext4 layout while feeding the same emitted bytes into
   the inline rootfs CAS writer. The CAS writer classifies zero chunks, writes
   missing nonzero objects durably, and publishes the `spore-disk-index-v1`
   after every referenced object is durable.

The current profile uses 4096-byte blocks, 256-byte inodes, sparse
superblocks, filetype directory entries, external xattr blocks, inline symlinks
shorter than 60 bytes, and block-mapped regular files with direct, single-indirect,
and double-indirect blocks. Larger files fail closed until extents or
triple-indirect blocks are added.

## Safety Model

OCI layers and local rootfs tars are attacker-influenced input. The merged-tree
path rejects unsafe paths, symlink traversal, invalid hardlinks, unsupported
xattrs, and size/count limit violations. The writer re-checks path safety,
inode counts, image size, link counts, xattr bounds, and unsupported file sizes
before writing.

The default native flip is a flag-day cache break: `builder_version` is
`sporevm-rootfs-v6`, so old `v3`/`v4`/`v5` rootfs cache entries are abandoned and rebuilt.
The by-digest cache is not split by writer. Rootfs metadata records the selected
writer, and cache validation rejects a metadata/artifact pair produced by the
other writer so `SPOREVM_EXT4_WRITER=external` remains an effective escape
hatch.

## Current State

Implemented in this branch:

| Area | Status | Evidence |
| --- | --- | --- |
| Synthetic ext4 emission | Done | Deterministic images, multi-group images, hardlinks, device/special files, xattrs, large double-indirect files, and fsck checks run through `zig build rootfs-slow-test`; planner/fuzz coverage remains in `src/rootfs/ext4_writer.zig`. |
| Merged tree from layer tars | Done | `src/rootfs/tar.zig` builds source-backed merged trees and compares them with staging semantics for whiteouts, hardlinks, symlinks, ownership, xattrs, implicit dirs, and content. |
| Native materialization wiring | Done | `materializeRootFS` selects native by default, external by `SPOREVM_EXT4_WRITER=external`, and writes `ext4_writer` into rootfs metadata. |
| Native/external semantic parity | Done | Focused debugfs read-back test in `src/rootfs_slow_tests.zig` imports the same tar through both writers and compares guest-visible file contents; repeated native output has the same BLAKE3. |
| Determinism | Done | Duplicate native emits and repeated native materialization produce stable BLAKE3 for the tested inputs. |
| Fuzz coverage | Done | Existing tar fuzzing is extended with merged-tree fuzzing, and the native planner/metadata emitter has an integrated fuzz target. |
| Cache identity | Done | Builder version bumped to `sporevm-rootfs-v6`; cache validation includes the selected writer metadata without hashing writer selection into the cache key. |
| Guest boot smoke | Done | Native-default OCI smoke built and booted Alpine during the v4/default-flip work with `ext4_writer: native` and guest output `native-rootfs-smoke`; v6 invalidates the cache identity for the chunk-index format break. |
| Writer benchmark | Done | Post-v5 native/external/tar2ext4 comparison and U4 chunked inline-index import comparison recorded below; optimized native output is e2fsck-clean. |

## Rollout Gates

Default PR CI:

- `zig build test` keeps parser, cache identity, native writer planner/fuzz, and
  cheap rootfs coverage in the fast lane.

Slow rootfs gate:

- Native-default OCI boot smoke passes and is recorded here.
- Focused native/external parity runs with `mise run test:rootfs-slow`;
  Buildkite can run the same slow lane by setting
  `SPOREVM_RUN_ROOTFS_SLOW_TESTS=1`.
- Cache and TLS tests pass after the v5 re-scope.
- Full `zig test src/rootfs.zig`, `mise run test`, and `mise run build` pass.

Before removing the external fallback:

- Native writer throughput is acceptable on representative large images.
- The first profile either supports extents/triple-indirect blocks or the
  `UnsupportedExt4FileSize` fallback remains documented and tested.

## Boot Evidence

Recorded on 2026-07-08 in this worktree:

```bash
tmp_cache="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-native-smoke-cache.XXXXXX")" &&
env -u SPOREVM_EXT4_WRITER SPOREVM_ROOTFS_CACHE_DIR="$tmp_cache" \
  test/smoke/rootfs/oci-run.sh --no-build \
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

Recorded on 2026-07-08 with
`scripts/benchmark/ext4-writer-comparison.py --tar <docker export of buildkite/agent:3>`
(312 MiB flattened tar for linux/arm64
`buildkite/agent@sha256:5f259c0f106051d59335ad9c7edb1dc0bfd4fe59ff115d70cbbcdbf813d87fe4`,
macOS arm64 host), after the v5 symlink-boundary fix and with patched
hcsshim `tar2ext4` from `/Users/lachlan/Develop/hcsshim` commit
`a4436aefe3f3` (`microsoft/hcsshim#2811`, inode bitmap padding fix):

| Tool | Wall | Conversion | Output size | e2fsck -fn |
| --- | ---: | ---: | ---: | --- |
| `spore (native)` | 9.79s | 6.31s | 592 MiB | clean |
| `spore (external)` | 13.92s | 6.14s | 592 MiB | clean |
| `tar2ext4` (hcsshim patched) | 651ms | 651ms | 323 MiB | clean |
| `tar2ext4 -inline` (hcsshim patched) | 183ms | 183ms | 323 MiB | clean |

The native v5 run recorded rootfs size `620756992`, BLAKE3
`f9f0af0c72363592a6bef9a00c0545c72d95cbd9cd7535988d11ac4e2a867808`. The
external writer produces different ext4 bytes for the same guest-visible tree,
also fsck-clean and the same padded size.

The patched hcsshim outputs are now fsck-clean, so compactext4 is a clean
performance target rather than a fast-but-fsck-noisy reference. The remaining
gap is mostly architectural: Spore emits and hashes a fixed-size padded block
device, while hcsshim streams a compact ext4 layout with extents and optional
inline data. The next ceiling is still sub-second conversion for this size
class, but getting there means compact layout/extent work rather than more
rootfs CAS plumbing.

### U4 Inline Chunk Index

Recorded on 2026-07-08 in this worktree with the same 312 MiB flattened
`buildkite/agent:3` tar, chunked rootfs storage, and:

```bash
/usr/bin/time -p env \
  SPOREVM_EXT4_WRITER=native \
  SPOREVM_ROOTFS_BUILD_PROFILE=1 \
  SPOREVM_ROOTFS_CACHE_DIR="$PWD/zig-cache/ext4-writer-comparison-inline-chunked/spore-native/cache" \
  zig-out/bin/spore rootfs import-tar \
  /Users/lachlan/Develop/sporevm/zig-cache/rootfs-inputs/buildkite-agent-3-linux-arm64.tar \
  --ref local/ext4-writer-bench:inline-native \
  --rootfs-storage chunked \
  --platform linux/arm64
```

| Writer | Wall | Profile total | Ext4 emit | CAS/index phase | Output size | e2fsck -fn |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `spore (native inline)` | 6.95s | 5.106s | 3.392s | `rootfs_cas_inline` 3.392s | 592 MiB | clean |
| `spore (external preload)` | 13.58s | 12.417s | 1.098s mkfs/debugfs | `rootfs_cas_preload` 4.870s | 592 MiB | clean |

Native inline emitted 9,472 index chunks: 4,267 zero chunks and 5,205
nonzero objects, writing 341,114,880 object bytes and a 728,817 byte index.
The inline CAS/index phase is the same wall interval as `native_ext4_emit`;
there is no second full-image scan after the native writer finishes. The
external fallback still pays `rootfs_cas_preload` after e2fsprogs has produced
the flat image.

## Inline Chunk Index Emission For U4

The U4 storage slice extended the native writer emission loop so every 64 KiB of
logical image bytes also feeds a chunk hasher and writes/records the
corresponding CAS object for `spore-disk-index-v1`.

Keep the current writer loop friendly to future writer work:

- Preserve the sequential block walk in `writeImage`.
- Avoid adding new callers that depend on the current `Result` shape as the
  durable writer API.
- Do not expand `ensureImageRootfsStorage`, storage upgrade, or chunked-to-flat
  assembly paths; those remain outside the native writer contract.

## Known Limits

- A single regular file larger than direct + single-indirect + double-indirect
  coverage, roughly 4 GiB with 4 KiB blocks, fails closed with
  `UnsupportedExt4FileSize`. Use `SPOREVM_EXT4_WRITER=external` for images with
  larger files until extents or triple-indirect support lands.
- Large-directory lookup is linear because `dir_index` is not emitted.

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
