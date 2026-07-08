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
  cas/rootfs/blake3/indexes/<id>.json # spore-disk-index-v1
  cas/rootfs/blake3/objects/<id>.chunk
```

`spore run --image ... --save` is the writable-rootfs product path. It
records the immutable ext4 artifact, records `rootfs.storage` from the metadata
sidecar for image-created spores, and captures rootfs writes as sealed disk
layers over that base. Older image cache entries are upgraded once when save
needs portable chunked rootfs identity. `spore rootfs cas-preload --attach-spore`
remains a repair/debug path for existing exact-rootfs spores; it is not the
normal producer path.

Plain `spore run --rootfs PATH` is still a local read-only escape hatch. Named
`spore create --rootfs PATH` records exact immutable rootfs identity in the
digest cache, so lifecycle saves can restore through the fd-backed rootfs
path. Combining one-shot `spore run --rootfs PATH` with `--save` is rejected
until an import path can record chunked portable rootfs identity for arbitrary
local images.

`spore run --inject ID=PATH` injects caller-provided bytes into
`/run/sporevm/injected/ID` for a fresh run. The bytes are appended to the run
initrd and, when a rootfs is attached, copied into the rootfs `/run` tmpfs
before the command starts. They are not installed into the image rootfs cache or
the immutable rootfs artifact. Spore rejects `--inject` with `--save` and
`--from` so injected bytes are not accidentally captured into a persisted spore.

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
- `disk.kind: "chunk-index-disk-v0"` records sealed writable root disk bytes as
  a `spore-disk-index-v1` in the rootfs CAS namespace. `disk.base` is the index
  digest; `chunk_size`, `hash_algorithm`, and `object_namespace` bind the
  descriptor used to open and verify the index and objects.

OCI refs and local image ref records are provenance or cache hints only.

## Runtime Path

Product attach and run-from restore build one root disk backend:

```text
virtio-blk
  -> one-level chunk map
  -> sparse local overlay for writes
  -> flat materialized base fd rebuilt from the selected disk/rootfs index
```

The flat materialization is the hot runtime base source. For immutable rootfs
artifacts, the open follows the verify-at-install, trust-at-open cache contract
(see SECURITY.md): entries were BLAKE3-verified when installed and published
read-only, so the open checks only symlink-safety, regular-file shape, and
exact size instead of re-hashing the artifact. Writable disk indexes are
materialized into a temporary flat fd by verifying the index and each referenced
chunk object first. Serving guest reads with plain preads on one fd is what
keeps resume-to-first-command fast.

Chunked rootfs storage (`rootfs.storage`) is a distribution and dedupe format,
not a runtime read path. `spore pull` and `spore unpack` assemble the flat
artifact from the verified chunk objects at materialization time, and resume
performs the same assembly once when the flat artifact is missing locally
(pruned or corrupt cache entries self-heal from chunks). Assembly verifies
each chunk against the digest-verified index, hashes the assembled bytes, and
requires them to equal `rootfs.artifact.digest` before atomically publishing
the entry; an inconsistent artifact/index pairing fails closed instead of
serving different bytes depending on cache state.

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
become restore authority. HTTP peer hosts must resolve only to public IP
addresses; loopback, link-local, private, multicast, and reserved targets are
rejected before a GET is issued.

Metadata-only exact-rootfs bundles are an explicit prepared-cache opt-out:
`--rootfs=metadata-only` on pack and `--allow-metadata-only-rootfs` on
unpack/pull. Chunked rootfs storage is bundled by default for new image-created
spores.

## Cache Inspection And Pruning

`spore system df --rootfs` reports image ext4 files, metadata, exact digest
artifacts, rootfs CAS indexes, rootfs CAS objects, ref records, and temporary
entries. `spore cache gc --rootfs` performs a mark/sweep of rootfs CAS indexes
and objects from cache metadata, ref records, and live runtime manifests; it is
dry-run by default and requires `--force` to delete candidates.

Default `spore system prune --rootfs` only selects rebuildable image rootfs
entries. Flat digest artifacts (the resume authority) are skipped unless
`--include-digest-artifacts` is passed with an age or size bound. Derived
rootfs CAS chunks are skipped unless `--include-rootfs-chunks` is passed;
pruning them is safe when the flat artifact remains because resume serves the
flat artifact and `spore pack` re-derives chunks from it.

## Evidence

The default manifest-attached rootfs CAS path is materially faster than the
historical verify-on-open fd-backed control on local HVF for
`docker.io/library/node:22-alpine`:

```text
count  baseline median TTI  manifest CAS median TTI
10     7031.5 ms            606.0 ms
100    6983.5 ms            561.5 ms
```

The same benchmark showed median rootfs verification dropping from about 3.35s
and 536.9MiB hashed to about 270-284ms and 31.98MiB hashed for the sparse Node
working set.

The later trust-at-open flat-artifact preference removed the remaining
per-chunk object-open cost from warm resume. On the same local HVF
Node workload, the CI benchmark profile measured warm `spore run --from`
median TTI dropping from 391ms (CAS chunk base) to 73ms (flat artifact base),
with guest `node -v` execution time inside the resumed VM dropping from about
300ms to about 22ms. Cold TTI was unchanged.

## Deferred Work

- Broader image-registry measurements for chunk-size tuning.
- Optional file-content indexes if fixed block dedupe leaves measured package or
  model-transfer savings on the table.
- Lazy remote rootfs reads and scheduler-aware peer selection.
- Packfile support if fault-in measurements show file-per-chunk is too costly.
