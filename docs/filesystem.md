# Filesystem And Root Disk Contract

SporeVM exposes root storage to the guest as a normal `virtio-blk` disk. The
host may serve that disk from an exact ext4 artifact, a chunked rootfs CAS, or
sealed writable COW layers, but the guest-visible contract stays block-based.
Filesystem-level diffs, FUSE, 9p, NFS, and file-content indexes are not restore
authority.

## Rootfs Production

`spore rootfs build` materializes an OCI image into a deterministic ext4 image,
installs that image into the digest cache, and writes chunked rootfs CAS storage
by default:

```text
$SPOREVM_ROOTFS_CACHE_DIR/
  <image-cache-key>.ext4
  <image-cache-key>.json              # includes rootfs_storage
  by-digest/blake3/<rootfs>.ext4      # exact fd-backed compatibility path
  cas/rootfs/blake3/indexes/<id>.json # rootfs-block-index-v0
  cas/rootfs/blake3/objects/<id>.chunk
```

`spore run --image ... --capture` records the immutable ext4 artifact and, for
image-created spores, records `rootfs.storage` from the metadata sidecar. Older
image cache entries are upgraded once when capture needs portable chunked rootfs
identity. `spore rootfs cas-preload --attach-spore` remains a repair/debug path
for existing exact-rootfs spores; it is not the normal producer path.

Plain `spore run --rootfs PATH` is still a local escape hatch. Combining
`--rootfs PATH` with `--capture` is rejected until an import path can record
portable rootfs identity for arbitrary local images.

## Manifest Authority

The manifest, not a path, tag, cache entry, or bundle index, is the restore
authority.

- `rootfs.artifact` records the exact ext4 artifact digest, size, format, device
  binding, and OCI provenance. This remains the compatibility path for spores
  without `rootfs.storage`.
- `rootfs.storage.kind: "chunked-ext4-rootfs-v0"` selects the chunked rootfs
  base. The descriptor binds device, logical size, chunk size, hash algorithm,
  object namespace, `index_digest`, and `base_identity`. For this storage kind,
  `base_identity == index_digest`.
- `disk.kind: "cow-block-v0"` records sealed writable root disk layers over the
  effective rootfs base. For fd-backed rootfs, `disk.base` is the ext4 artifact
  digest. For chunked rootfs, `disk.base` is `rootfs.storage.base_identity`.

OCI refs and local image ref records are provenance or cache hints only.

## Runtime Path

Product resume builds one root disk backend:

```text
virtio-blk
  -> local active COW head
  -> sealed disk-layer objects
  -> immutable base block source
       FileBlockSource: verified ext4 fd
       CasBlockSource: verified rootfs index plus verified chunks
```

`CasBlockSource` opens the exact `rootfs-block-index-v0` named by
`rootfs.storage.index_digest`, validates descriptor fields, and verifies each
chunk by BLAKE3 before guest use. It memoizes verified chunks for the VM so
repeated small guest reads do not rehash the same object.

`FileBlockSource` is only used when the manifest has no `rootfs.storage`. It
opens the digest-addressed ext4 artifact read-only and verifies the same fd by
BLAKE3 and size before attaching the block backend.

Missing or corrupt rootfs indexes, chunk objects, exact artifacts, disk layer
indexes, or disk objects fail before guest code can observe the bytes.

## Writable Disk Layers

Writable rootfs state is represented as sealed block layers:

```text
disk-layer-v0
  cluster_size: 4096
  disk_size: <bytes>
  extents: logical_cluster -> blake3:<cluster-bytes>
  zero_clusters: [...]
```

Active writes stay local in a sparse writable head. Capture seals dirty clusters
into content-addressed disk objects and records the layer index in the manifest.
Forking preserves sealed parent layers and gives each child a fresh writable
head. A later file-content index may reduce transfer bytes for shifted package
layouts, but exact block replay remains authority.

## Distribution

`spore pack` follows the selected manifest:

- spores without `rootfs.storage` include exact rootfs bytes under
  `rootfs/blake3/<hex>.ext4`;
- spores with `rootfs.storage` include the descriptor-bound index under
  `rootfs/blake3/indexes/<hex>.json` and referenced chunks under
  `rootfs/blake3/objects/<hex>.chunk`;
- spores with writable disk layers include referenced `disk-layer-v0` indexes
  and disk cluster objects.

`spore unpack` and `spore pull` fully materialize one selected child before
resume. They verify bundle identity, selected manifests, RAM chunks, rootfs
artifacts or CAS bytes, and disk objects before writing a resumable spore.
Direct S3 and digest-pinned HTTP peer pulls are byte sources only; they never
become restore authority.

Metadata-only exact-rootfs bundles are an explicit prepared-cache opt-out:
`--rootfs=metadata-only` on pack and `--allow-metadata-only-rootfs` on
unpack/pull. Chunked rootfs storage is bundled by default for new image-created
spores.

## Cache Inspection And Pruning

`spore system df --rootfs` reports image ext4 files, metadata, exact digest
artifacts, rootfs CAS indexes, rootfs CAS objects, ref records, and temporary
entries.

Default `spore system prune --rootfs` only selects rebuildable image rootfs
entries. Exact digest artifacts and rootfs CAS files can be required by existing
captured spores, so they are skipped unless `--include-digest-artifacts` is
passed with an age or size bound.

## Evidence

The default manifest-attached rootfs CAS path is materially faster than the
fd-backed control on local HVF for `docker.io/library/node:22-alpine`:

```text
count  baseline median TTI  manifest CAS median TTI
10     7031.5 ms            606.0 ms
100    6983.5 ms            561.5 ms
```

The same benchmark showed median rootfs verification dropping from about 3.35s
and 536.9MiB hashed to about 270-284ms and 31.98MiB hashed for the sparse Node
working set.

## Deferred Work

- Broader image-registry measurements for chunk-size tuning.
- Optional file-content indexes if fixed block dedupe leaves measured package or
  model-transfer savings on the table.
- Lazy remote rootfs reads and scheduler-aware peer selection.
- Reachability-aware rootfs CAS garbage collection.
