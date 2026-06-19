---
status: complete
last_reviewed: 2026-06-20
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/distribution.md
  - docs/spore-format.md
  - SECURITY.md
  - src/virtio/blk.zig
  - src/cow_disk.zig
  - src/disk_layer.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/distribution.md
  - docs/plans/immutable-rootfs-resume.md
---

# Writable Disk Layer Plan

## Summary

Writable disk support should be a host-side COW block layer behind the existing
`virtio-blk` device. The guest keeps seeing one ordinary block device. SporeVM
keeps the current immutable rootfs digest as the base artifact, then records
sealed writable disk layers as content-addressed objects.

The restore authority is the block-layer chain, not a guest filesystem export:

```text
immutable rootfs ext4 artifact
+ sealed writable disk layers
+ local active writable head
```

The runtime hot path optimizes for local block performance. Snapshot, pack, and
pull optimize for content-addressed distribution. A later file-content index may
improve dedupe for shifted package installs or model files, but it must remain
advisory. Exact block-layer replay is the thing that makes a VM resume correct.

## Problem

Before this track, SporeVM could capture diskless VMs or VMs with one immutable
read-only rootfs artifact, but not the guest's disk mutations. General block
devices remain outside scope, but rootfs-bound writable state is the product path
where an agent installs packages, writes a workspace, snapshots the machine, and
fans out 10k cheap writable forks.

Copying full disk images per fork is not viable. It destroys distribution
economics and makes cross-cloud placement depend on shipping large opaque block
images. Moving writable state into a guest FUSE filesystem would make snapshots
depend on guest-side client behavior and would stop the root disk from being an
exact `virtio-blk` replay contract.

## Goals

- Preserve the existing guest-visible device model.
- Let rootfs-backed workloads write to their root disk, capture those writes,
  resume them, and fork children that share the sealed parent disk layers.
- Make the portable disk artifact content-addressed and verified before guest
  use.
- Keep active writes local and low-latency; do not put S3, peer fetch, or FUSE
  on the guest progress path.
- Extend pull-based bundles so disk layers reuse node-local caches and peer or
  object-store byte sources.
- Measure cluster-size, dedupe, and pack/pull economics before picking the
  runtime artifact defaults.

## Non-Goals

- Multi-writer shared filesystem semantics inside one disk chain.
- Guest-visible FUSE, NFS, 9p, or virtio-fs as the root disk contract.
- Cross-filesystem semantic diffing as restore authority.
- Live migration of a dirty active disk head.
- Public compatibility before 1.0.

## Target Model

The manifest carries a writable disk section when a captured rootfs-backed VM
has sealed disk state:

```text
disk:
  kind: cow-block-v0
  device: virtio-mmio rootfs slot
  size: <bytes>
  base: blake3:<immutable-rootfs-ext4>
  layers:
    - blake3:<layer-index>
```

A sealed layer is an extent index plus content-addressed disk cluster objects:

```text
layer:
  kind: disk-layer-v0
  cluster_size: 4096 | 16384 | 65536 | ...
  extents:
    logical_cluster -> blake3:<cluster-bytes>
  zero_clusters:
    - logical_cluster
```

Reads walk newest to oldest: active head, sealed layers, immutable rootfs. Writes
only update the active head. Capture pauses vCPUs, requires quiescent virtio-blk
queues, captures RAM, and records sealed dirty clusters against that same stopped
VM point. Forking preserves the sealed disk chain and gives each child a fresh
empty active head.

Distribution extends the current bundle shape:

```text
bundle/
|-- manifests/
|-- chunkpacks/        # RAM chunks
|-- rootfs/            # immutable base ext4 bytes
|-- disklayers/        # sealed layer indexes
`-- diskobjects/       # content-addressed disk clusters
```

## Safety Invariants

- The immutable rootfs digest remains restore authority for the base ext4 bytes.
- Disk layer indexes and disk objects are verified before resume can attach
  them to a VM.
- `spore resume` fails before VM creation on a missing, corrupt, or unsupported
  disk layer.
- Snapshot requires quiescent virtio-blk queues or a designed serialization
  contract for pending requests.
- Local active heads are not portable trust roots until sealed.
- Optional file-content indexes cannot change restore semantics; they can only
  reduce transport or cache bytes.

## Current Experiment

The first experiment is intentionally offline. It does not need KVM/HVF or an
implemented COW backend. It asks a narrow question: how sensitive are sealed disk
layer bytes to cluster size and layout noise?

Run:

```console
scripts/experiment-disk-layer-economics.py --profile full
scripts/experiment-disk-layer-economics.py --profile ext4
```

The synthetic profile generates deterministic disk images for four workloads:

- `aligned-package`: common package payloads land at stable offsets.
- `shifted-package`: the same payloads land at different offsets and order.
- `metadata-jitter`: stable file data plus per-variant metadata noise across
  many clusters.
- `sqlite-like`: repeated 4KiB page rewrites and WAL-style appends.

The ext4 profile uses `mkfs.ext4 -d` from e2fsprogs to create real ext4 images
from deterministic directory trees. It is still offline and does not simulate
in-place journal history, but it exercises real ext4 placement and metadata.

Initial full-profile results:

```text
workload           cluster  unique-block  total-block   logical   block/log  block/file  objects
aligned-package        4K       19.14M       99.53M     99.53M      1.00x       1.00x     4900
aligned-package       16K       19.23M       99.62M     99.53M      1.00x       1.00x     1231
aligned-package       64K       19.94M      100.00M     99.53M      1.00x       1.04x      319
shifted-package        4K      102.74M      102.78M     99.53M      1.03x       5.37x    26302
shifted-package       16K      107.03M      107.03M     99.53M      1.08x       5.59x     6850
shifted-package       64K      107.31M      107.31M     99.53M      1.08x       5.61x     1717
metadata-jitter        4K       24.17M       99.53M     99.82M      1.00x       1.26x     6188
metadata-jitter       16K       39.36M       99.62M     99.82M      1.00x       2.06x     2519
metadata-jitter       64K      100.00M      100.00M     99.82M      1.00x       5.22x     1600
sqlite-like            4K       42.58M       42.58M     47.56M      0.90x           -    10901
sqlite-like           16K       98.86M       98.86M     47.56M      2.08x           -     6327
sqlite-like           64K      137.25M      137.25M     47.56M      2.89x           -     2196
```

Initial ext4-profile results:

```text
workload           cluster  unique-block  total-block   logical   block/log  block/file  objects
ext4-aligned-package     4K       13.83M       43.53M     42.11M      1.03x       1.03x     3540
ext4-aligned-package    16K       14.20M       43.88M     42.11M      1.04x       1.06x      909
ext4-aligned-package    64K       15.56M       45.00M     42.11M      1.07x       1.16x      249
ext4-shifted-package     4K       23.59M       43.59M     42.11M      1.04x       1.76x     6039
ext4-shifted-package    16K       40.94M       43.88M     42.11M      1.04x       3.06x     2620
ext4-shifted-package    64K       43.50M       45.00M     42.11M      1.07x       3.25x      696
ext4-metadata-jitter     4K       17.24M       47.53M     42.40M      1.12x       1.26x     4414
ext4-metadata-jitter    16K       17.58M       47.81M     42.40M      1.13x       1.28x     1125
ext4-metadata-jitter    64K       19.00M       49.00M     42.40M      1.16x       1.39x      304
ext4-sqlite-final        4K        7.11M        8.02M      6.73M      1.19x       1.06x     1821
ext4-sqlite-final       16K        7.47M        8.31M      6.73M      1.23x       1.11x      478
ext4-sqlite-final       64K        8.75M        9.50M      6.73M      1.41x       1.30x      140
```

Findings:

- Stable package layouts dedupe well with fixed blocks. 16KiB was effectively
  tied with 4KiB in the synthetic package profile and about 3% worse in the
  ext4 profile; 64KiB was about 4% worse synthetically and about 13% worse in
  ext4.
- Shifted package layouts defeat fixed block dedupe regardless of cluster size.
  The ext4 profile showed 16KiB using about 1.7x the unique bytes of 4KiB and
  64KiB using about 1.8x, so a file-content index would be materially better for
  that class.
- Metadata noise can punish larger clusters. The synthetic profile is a worst
  case where even 16KiB was about 1.6x the unique bytes of 4KiB; the ext4
  profile was milder but still favored smaller clusters.
- SQLite-like page writes also punish larger clusters. 64KiB moved about 3.2x
  the unique bytes of 4KiB in the synthetic page-write profile, and 16KiB moved
  about 2.3x. The ext4 final image profile was milder because it does not
  capture in-place write history.

This points to 4KiB as the first restore-authority cluster size, with pack-level
aggregation to avoid object-store object explosion. 16KiB remains worth testing
only if runtime metadata or index overhead dominates. Starting with 64KiB would
be attractive for metadata size, but the current evidence says it is risky for
databases and metadata-heavy package installs.

## Delivery Strategy

### Slice 1: Offline Economics Harness

Status: implemented locally.

Land and iterate the synthetic disk-layer experiment. Add real ext4 image
experiments when running on a Linux host with `mkfs.ext4` and `debugfs`
available.

Done when the experiment can compare fixed block clusters, shifted file
payloads, metadata noise, and SQLite-like page writes, and the results are
recorded here.

### Slice 2: Local COW Block Backend

Status: implemented locally. `src/cow_disk.zig` is wired into `virtio-blk`
behind a `.cow` backend. Runtime rootfs artifact paths get a local sparse active
head, while direct `--rootfs` paths still attach a plain read-only fd. The
`smoke:writable-rootfs` product smoke writes through the guest-visible root disk,
captures, and verifies the captured contents after replay.

Add a `virtio-blk` backend that reads from an immutable base fd plus a local
active writable head. The first implementation can use a sparse overlay file and
dirty-cluster map. It does not need pack/pull support.

Done when a rootfs-backed VM can write files, capture, resume, verify contents,
and reject corrupt or missing active-head data before boot.

### Slice 3: Seal One Disk Layer

Status: implemented locally. The local sealer writes BLAKE3-addressed disk
objects and a BLAKE3-addressed `disk-layer-v0` JSON index. Capture records a
validated `disk` chain when the writable head has dirty clusters. `spore resume`
and `spore run --from` attach that chain through a layered COW backend, so later
captures append a new sealed layer instead of rewriting the parent layers.
Bundle/pull materialization carries those layers in local, S3, and HTTP(S)
bundle paths.

Seal the active head into a disk layer index plus content-addressed cluster
objects. Record the layer chain in the manifest and restore from base plus layer.

Done when capture/resume works without depending on local active-head paths.

### Slice 4: Fork Writable Disk Chains

Status: implemented locally. `spore fork` preserves the sealed disk chain in
child manifests, symlinks the parent's disk layer/object stores into child
directories, and runtime resume gives each child a fresh active head.
`smoke:writable-rootfs` forks a captured writable parent into four children,
boots the children, checks they all see the parent disk write, captures a new
write from child 0, and proves the siblings do not see child 0's layer.

Teach `spore fork` to preserve the sealed disk chain and give children empty
writable heads. Children must diverge independently after resume.

Done when one captured parent can fork many children, each child sees parent disk
writes, and child-specific writes do not affect siblings.

### Slice 5: Bundle And Pull Disk Layers

Status: implemented and KVM-smoked. `spore pack`
copies manifest-referenced disk layer indexes and disk objects into single-spore
and indexed bundles, `bundle_digest` covers those bytes, `spore push` uploads
the canonical disk files, and local/S3/HTTP(S) `spore pull` downloads and
verifies them before writing a resumable spore. `smoke:writable-rootfs` also
packs and unpacks a real two-layer writable rootfs capture, then boots from the
unpacked spore.

Remote KVM proof on 2026-06-20 used two same-class `a1.metal` hosts:

```console
scripts/smoke-remote-bundle.sh \
  --region ap-southeast-2 \
  --source-instance i-07ccd00f26fbaec6d \
  --dest-instance i-07ccd00f26fbaec6d \
  --dest-instance i-0521d926e8cba111d \
  --bucket cleanroom-dev-apse2-arm-ap-southeast-2-724772075326 \
  --run-id writable-rootfs-20260619T212758Z \
  --writable-rootfs \
  --include-untracked \
  --dest-repeat 2 \
  --cache-dir /tmp/sporevm-remote-bundle-cache-writable-rootfs-20260619T212758Z
```

The run captured an Alpine rootfs-backed writable parent, forked two children,
packed the disk layer into an S3 bundle, pulled both children on both hosts,
booted them with `spore run --from`, rejected one corrupt disk object per host,
and proved warm cache reuse: iteration 2 on each host reported
`remote_bundle_cache_hit=true`, `origin_bytes_read=0`,
`chunk_bytes_fetched=0`, and `rootfs_bytes_fetched=0`. The bundle carried 12
disk objects, 49,152 bytes of disk object payload, and digest
`38cd7e6539cb77b81533e1c66b3c88a190cd668b6a60925c007afcfd77580060`.

Extend `spore pack`, `spore pull`, and cache metrics to include disk layer
indexes and disk objects. Keep the same pull-before-resume failure boundary as
memory and rootfs bundles.

Done when remote materialization verifies disk objects, reuses cache hits across
children, and fails closed on corrupt disk objects or indexes.

### Slice 6: Optional File-Content Index

Only add this if real package/model experiments show fixed block dedupe leaves
large savings on the table. The index can map file payload digests to disk
cluster reconstruction hints, but exact block objects remain restore authority.

## Verification

- Unit tests for disk layer parser rejection: duplicate extents, out-of-range
  clusters, digest mismatch, missing base, explicit zero-overrides, and
  unsupported cluster sizes.
- Fuzz targets for disk layer indexes in the same slice that introduces them.
- Sealer/reader tests for COW dirty clusters, explicit zero-cluster overrides,
  layer index digest verification, and disk object digest verification.
- Runtime setup tests for `resume` and `run --from` proving disk-layer manifests
  are attached through the layered COW backend, plus snapshot tests proving dirty
  layered heads append only new layers.
- Block backend tests for read precedence, overwrite behavior, flush behavior,
  sparse holes, and active-head corruption.
- Product smoke: `mise run smoke:writable-rootfs` writes files inside a
  rootfs-backed VM, captures, appends a second layer through `run --from`, and
  verifies both layers replay before and after local bundle pack/unpack.
- Fork smoke: `mise run smoke:writable-rootfs` forks a writable parent, verifies
  each child sees the parent layer, then proves child-specific writes diverge.
- Distribution smoke: `scripts/smoke-remote-bundle.sh --writable-rootfs`
  passed on same-class KVM hosts with run id
  `writable-rootfs-20260619T212758Z`, proving pulled children boot with the
  captured disk layer, corrupt disk objects are rejected before boot, and warm
  cache origin bytes drop to zero for later child pulls on the same host.
- Performance guard: `scripts/benchmark-writable-rootfs.sh` records JSONL rows
  for fresh COW capture, sealed-layer append, and sealed-layer replay. A
  one-iteration KVM run on `i-0521d926e8cba111d` with run id
  `benchmark-writable-rootfs-20260619T221322Z` passed SQLite and package-style
  file expansion workloads:
  - SQLite: fresh COW capture 92,418 ms, sealed append 37,829 ms, sealed replay
    32,290 ms.
  - Package-style: fresh COW capture 90,294 ms, sealed append 35,780 ms, sealed
    replay 31,698 ms.
  - The optional `--raw-rootfs` row is read-only because the product CLI does
    not expose a writable raw rootfs mode.

## Open Questions

- Default disk cluster size. The first implementation uses 4KiB because the
  initial experiment favored it for unique bytes; 16KiB only stays in contention
  if runtime overhead or object packing dominates.
- Whether file-content indexing is worth the complexity. Synthetic shifted
  layouts say maybe; real ext4/package experiments should decide.
- Whether the sparse-file active head remains the right runtime default after
  broader performance measurements. The first KVM guard says sealed-layer append
  and replay are materially faster than fresh image-backed COW capture for the
  measured workloads, but this is a one-iteration guard, not a release SLO.

## Key Learnings From Pressure-Testing

- Large clusters are tempting because they reduce metadata, but they amplify
  metadata and database-like writes. The plan now keeps cluster size unsettled
  until runtime benchmarks exist, and the first evidence points smaller.
- File-content dedupe is useful when identical payloads land at shifted offsets,
  but making it restore authority would create a filesystem-semantic contract.
  It stays deferred and advisory.
- Object-store economics should be solved by packing many small verified disk
  clusters into seekable pack files, not by making clusters large enough to hurt
  databases.
