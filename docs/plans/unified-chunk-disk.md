---
status: active
last_reviewed: 2026-07-08
spec_refs:
  - docs/spore-format.md
  - docs/rootfs.md
  - docs/filesystem.md
  - SECURITY.md
  - src/spore.zig
  - src/disk_layer.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/runtime_disk.zig
  - src/dirty_ram.zig
related_plans:
  - docs/plans/spore-build.md
  - docs/plans/native-ext4-writer.md
---

# Unified Chunk-Mapped Disk

## Summary

Collapse SporeVM's two parallel content-addressed disk systems — sealed disk
layers (4KiB clusters, stacked at restore) and the chunked rootfs CAS (64KiB
chunks, flat) — into one primitive: **a disk state is a chunk index**, and its
identity is the BLAKE3 of that index. Base images, save snapshots, and
running-VM disks all become values of this one type. Flat ext4 files demote
from format objects to rebuildable materialization caches.

This is the storage architecture for SporeVM's core product goals: **fast
boot** and **fast fork**, with OCI images (`spore run --image`) as a
first-class import edge. Fork becomes a map copy plus a fresh overlay instead
of a layer-chain stack; boot becomes "open an index" instead of "assemble a
flat file"; publishing any disk state becomes an O(dirty) snapshot instead of
an O(image) hash. The simplification — deleting one of two COW/delta/identity
mechanisms before both calcify — is how those goals get met with less code,
not a separate justification. The plan deliberately breaks the on-disk and
manifest formats to do so.

## Product Goals This Serves

SporeVM's runtime direction is spores that start fast, fork fast, and can be
sourced from OCI images without a slow conversion tax. These goals converge
on one storage design rather than competing:

- **Fast fork.** Forking a disk must not deepen a read chain. Today
  `LayeredCowDisk` stacks layers newest→oldest, so lineage depth costs every
  read. With a chunk map, fork is: copy the in-memory map, give the child a
  fresh overlay. Depth-N lineage reads cost the same as depth-0. The map *is*
  the dirty state, so the parent's identity is recoverable at any point in
  O(dirty).
- **Fast boot.** Warm boot (materialization cached) is already cheap. Cold
  boot is gated on building a full flat ext4 before the VM can start. An
  index-addressed disk permits **partial materialization**: boot as soon as
  boot-critical chunks are present, serve the rest from the CAS on fault,
  fill in the background. That is impossible while the flat file is the
  identity-bearing artifact; it is a natural milestone once the index is.
- **OCI `--image`.** OCI stays an *edge*: layers are converted once into
  chunks + an index (native ext4 writer emitting inline, or full-scan
  fallback), and everything downstream — run, fork, build, save — is uniform.
  No OCI concept survives past import. Combined with partial materialization,
  cold `--image` start no longer pays for bytes the workload never reads.

`buildkite-sporevm` remains a useful benchmark (a large real image), but it is
an example, not the design driver.

## Problem

The tree carries two implementations of the same idea at different
granularities, plus a third identity that belongs to neither:

| Concern | Disk layers (`disk_layer.zig`) | Rootfs CAS (`rootfs_cas.zig`) |
| --- | --- | --- |
| Unit | 4KiB cluster | 64KiB chunk |
| Index type | `spore.DiskLayer` (`extents` + `zero_clusters`) | `rootfs-block-index-v0` (`chunks` + `zero_chunks`) |
| Composition | chain, read newest→oldest at runtime | flat, one level |
| Dirty tracking | `CowDisk`/`LayeredCowDisk` cluster bitmaps | none today (full scan); bitmap planned |
| Producer | `spore save` sealing | import preload / lazy storage upgrade |
| Consumer | resume/restore (`LayeredCowDisk`) | flat-file assembly before boot |

`spore.DiskLayer{ extents: [{logical_cluster, digest}], zero_clusters }` and
`DiskIndex{ chunks: [{logical_chunk, digest}], zero_chunks }` are the
same structure with different field names. Each has its own parser (both
restore-authority, both security surface per `SECURITY.md`), its own object
namespace, its own validation, its own tests.

On top of both sits `rootfs_blake3`, a linear hash of flat bytes that no
delta mechanism can maintain incrementally, forcing full-image scans at every
mutation-to-artifact boundary.

Left alone, this gets worse before better: the (deferred) `spore build`
plan would add a third write-persistence model (write-in-place + reflink
checkpoint), and the
obvious incremental fix — maintaining the existing `rootfs-block-index-v0`
with a new virtio-blk dirty bitmap and a dual-identity transition — would
have added a second dirty tracker and a second identity namespace on top.
(That direction was drafted and deliberately deleted in favor of this plan.)
Each mechanism is individually justified — and collectively it is four ways
of saying "these bytes changed; here is the new state".

## Goals

- One index type, one chunk granularity (64KiB), one object namespace, one
  restore-authority parser, one identity (`H(index)`), for every disk state.
- One runtime backend: an in-memory chunk map with exactly one level of
  indirection — no layer-chain stacking on the read path, ever.
- One persistence operation — **snapshot**: freeze, hash dirty chunks, write
  them to the CAS, emit a new index. `spore save` and import both produce
  their output through it (and build finalize would too, if the deferred
  `spore build` plan is revived).
- **Fork as a first-class disk operation**: copy the map, fresh overlay,
  constant cost regardless of lineage depth. The disk side of VM fork must
  never be the bottleneck.
- **Partial materialization**: boot from an index before the flat cache is
  complete, faulting unmaterialized chunks from the CAS. Cold boot and cold
  `--image` start stop paying for the whole image up front.
- **Memory/disk parity.** RAM already implements this model
  (`dirty_ram.zig`, `MemoryManifest`, `memoryFingerprintHex`); `chunk.ChunkId`
  is already the shared identity layer for both. Disk must not grow a
  parallel implementation of what RAM has: the chunk-sealing core is
  extracted and shared, and the index encoding converges so one parser
  serves both, parameterized by chunk size.
- Delete: `LayeredCowDisk`, layer-chain load/seal/restore, the
  `spore.DiskLayer` format, the 4KiB object namespace, the dual-identity
  transition, and the chunked→flat assembly special case.
- A CAS garbage collector, because once everything shares one store, GC is
  load-bearing rather than optional.

## Non-Goals

- No latency regression on today's warm paths, and concrete targets only
  where a slice names them (fork and partial-materialization slices carry
  their own "done when" measurements). A native Dockerfile builder and its
  cached-rebuild target belong to the deferred `spore build` plan; this
  plan's local-iteration wins are fast import (U4: inline chunk emission, no
  separate full-image hash) and fast cold start (U7: partial
  materialization).
- No cross-machine chunk distribution. The unified store and lazy fault-in
  make a remote chunk source natural later; building it is separate work.
- No memory-state fork. This plan covers the disk side only; VM memory
  fork/snapshot is separate work that this plan must not block (see Open
  Questions on namespace convergence).
- No change to the guest-visible device model. One virtio-blk, same
  virtqueue parsing, per the frozen-device-model rule. Only backend
  internals move.
- No content-defined chunking, no Merkle trees over the index, no chunk
  compression. Fixed 64KiB chunks and a flat index are enough for every
  consumer this plan serves.
- No backwards compatibility. Manifest v2 does not read v0/v1 saved spores;
  the by-digest cache re-keys; old caches are abandoned, not migrated.
  (Accepted: pre-1.0-style break, explicitly sanctioned for this plan.
  Release notes must say so loudly, per AGENTS.md.)

## Design

### The value: a chunk index

```
DiskIndex {
  kind: "spore-disk-index-v1"
  logical_size, chunk_size (64KiB), hash_algorithm
  chunks:      [{ logical_chunk, digest }]   // sorted, strict, complete
  zero_chunks: [u64]                          // with chunks: full coverage
}
identity = blake3(canonical index bytes)
```

This is `rootfs-block-index-v0` renamed and promoted: same validation rules
(coverage equality, strict ordering, range checks — `validateDiskIndex`
already enforces them), now the *only* way any disk state is named. A base
image, a checkpoint, a save snapshot, and "the disk of a running VM at freeze
point" are all just indexes. Deltas are not format objects: the delta between
two states is the set difference of their indexes, computed when needed.

### The runtime: one chunk-mapped backend

The `Backend` union's `file`/`cow`/`layered_cow` variants collapse into one:

```
ChunkMappedDisk {
  map: per-chunk entry → .base (offset in materialization)
                       | .overlay (offset in sparse local overlay)
                       | .zero
  base_fd: flat materialization of the opened index (the hot read path)
  overlay_fd: sparse temp file receiving writes
}
```

Reads consult the map (an in-memory array, 8 bytes per chunk ≈ 1MiB per 8G
disk); writes land in the overlay and flip the entry. Dirty state *is* the
map — the separate cluster bitmaps in `CowDisk` and the planned blk bitmap
disappear as distinct artifacts. A read-only run is the degenerate case where
no entry ever flips. Unaligned sub-chunk writes read-modify-write the chunk
into the overlay, exactly as `CowDisk` does with clusters today.

The flat materialization stays the hot path deliberately: object-store reads
per 64KiB would need packing to compete, and the materialization is already
what `runtime_disk.open` assembles today. What changes is its status — it is
a cache keyed by index identity, rebuildable from the CAS, deletable under
pressure, never itself an identity-bearing artifact.

### Fork

These are two distinct operations, not one operation with two
implementations — callers always know which they want:

- **`fork`** (ephemeral, fast): quiesce writes momentarily, copy the child's
  map from the parent's, reflink the parent's overlay (APFS clone,
  effectively O(1)) as the child's read-only second source, give the child a
  fresh empty overlay, resume both. No durable identity is produced; this is
  the fast-fork product primitive for fan-out. Still one map lookup per read
  — sources are fds, not a stacked chain.
- **`snapshot` + open** (durable): run `snapshot()` on the parent (O(dirty)
  hashing), open the resulting index for the child. Costs the hash, yields
  an identity — for lineage, caching, and publishing.

Reflink is a host-filesystem capability (APFS, XFS, btrfs), not a universal
one: on hosts without it, `fork` falls back to snapshot-then-open (or a
plain overlay copy). A defined fallback, not an assumption.

Either way the invariant holds: read cost is one map lookup regardless of
how many forks deep the lineage is. This is the structural difference from
`LayeredCowDisk`, where every fork would have deepened the read chain.

### Partial materialization

Once the index is the identity, the materialization no longer has to be
complete before boot. The backend gains a third map source, `.cas`: a read
of an unmaterialized chunk fetches the object, writes it into the
materialization at its logical offset, and flips the entry to `.base`. A
background filler walks the remaining `.cas` entries so steady-state reads
never touch the object store. Boot ordering: materialize boot-critical
chunks first (empirically: superblock, group descriptors, inode tables for
`/`, the kernel/init read set — measurable by tracing chunk faults of a
reference boot), start the VM, fill the rest behind it.

This converts cold boot and cold `--image` start from "wait for the whole
flat file" to "wait for the boot working set". It is a later slice, not a
prerequisite for the format unification, because fault-in adds runtime
complexity and a new failure mode (CAS miss at read time must fail the I/O
cleanly, never hang the guest).

### The operation: snapshot

```
snapshot(disk) -> DiskIndex:
  freeze/drain (v1: at the existing capture/save quiesce points — VM paused,
                virtio-blk drained; online mid-run snapshot deferred with
                the spore-build plan)
  for each overlay entry: blake3 chunk, write CAS object if absent
  new index = parent index with those entries replaced
  identity = blake3(new index); persist index; thaw
```

Target shape is O(dirty) by construction. `ChunkMappedDisk` retains the
opened parent index identity when a disk is opened from a chunk index, so
`snapshotIndex()` can seal only overlay-backed dirty chunks and emit the new
index as the parent index with dirty entries replaced. Clean chunks keep their
parent digest or zero entry without reading or hashing the materialized bytes
when the new index is published into the same CAS root that already holds the
parent objects. Disks opened without a parent index, or snapshots published
into a different CAS root, still use the full-scan path because there is no
self-contained prior identity to preserve in that destination store. The
operation already exists in the tree for RAM: `dirty_ram.zig` seals dirty 2MiB
memory chunks into verified chunk refs plus a same-host backing file, with
parallel workers, zero-scan elision, write-if-missing dedupe, and phase-level
stats.
Disk does not get its own sealer: U3 extracts the generic core out of
`dirty_ram.zig` into a shared module (working name `chunk_sealer.zig`)
parameterized by chunk size, dirty source, and object-write target, with
RAM-specific pieces (backing-file writes, the HMAC proof) staying in
`dirty_ram.zig` as a thin layer over it. The disk `snapshot()` and the RAM
sealer are then the same loop with different parameters, and sealer
improvements (parallelism tuning, stats) land once for both.

One invariant governs all producers: **an index is only ever written once
every chunk it references is durable in a store.** "Index exists" always
means "openable and GC-rootable"; there are no half-durable states for the
parser, restore, or GC to reason about.

Consumers:

- `spore save`: snapshot, then write a manifest referencing the index
  identity. Restore = open the index (materialize if needed), attach. No
  layer chains, no newest→oldest resolution, no `loadLayerChain`.
- `spore build` (future consumer, if the deferred plan is revived):
  intermediate step checkpoints do **not** get indexes — a step-key-addressed
  reflink clone of the live flat file is the whole checkpoint artifact, local
  and disposable. Emitting an index for an intermediate would require making
  its chunks durable first (the invariant), which would dominate snapshot
  time for artifacts that are usually thrown away. Build finalize would be
  one snapshot: chunks to the CAS, index identity as image identity, no
  terminal full-image hash.
- Import: the native ext4 writer emits chunks and an index inline; the
  fallback path is a full scan producing the same. `ensureImageRootfsStorage`
  and the storage-upgrade dance disappear — storage is always chunked; flat
  is always cache.

### Identity: one namespace

`H(index)` names every disk state. `rootfs_blake3` is deleted, not
deprecated: manifests, by-digest cache keys, ref records, and
`RootFSMetadata` all carry index identities. Equality, dedupe, and
cache-hit checks never touch image bytes. The determinism story improves
structurally: two differently-materialized flat files with identical logical
bytes have identical identity (linear hashing already had this property;
index hashing keeps it while being maintainable in O(dirty)).

One consequence to state plainly: verifying an artifact against its identity
means hashing chunks against the index, which parallelizes and can be lazy
(verify chunks on first read), unlike the linear scan. Verify-at-install
becomes verify-per-object-at-CAS-write plus index-digest check — cheaper and
finer-grained than today.

### GC

Mark-sweep over the one store: roots are indexes reachable from local refs,
image records, saved-spore manifests, and live build/step records; everything
else is collectable. Runs offline (`spore cache gc`), never concurrent with
a build/save in v1 (coarse lock). This must land before any deletion slice —
a unified store without GC is a disk-filling machine.

## What Gets Deleted

At end state:

- `disk_layer.zig`: `LayeredCowDisk`, `loadLayerChain`, seal chain,
  `SealResult`, layer refs. (`TempOverlay` survives, absorbed into the
  unified backend.)
- `spore.DiskLayer`, `DiskLayerExtent`, the 4KiB cluster object namespace,
  and their parsers/validation/tests.
- `spore.Disk.layers` and the disk/rootfs split in the manifest: a v2
  manifest references disks by index identity + role.
- `CowDisk` as a public type (its read-modify-write cluster logic lives on
  inside the unified backend).
- `rootfs_blake3` computation (`ext4.blake3File` call sites), the by-digest
  flat-file namespace as primary keys, `ensureImageRootfsStorage`, and the
  chunked→flat assembly special case in `runtime_disk.open`.
- Never built at all (drafted in the deleted incremental-index plan): a
  standalone virtio-blk dirty bitmap, a dual-identity/dual-namespace
  transition period, and chunk-delta checkpoints as a distinct mechanism —
  all subsumed by the map-is-dirty-state backend and the flag-day identity
  switch.

## Costs, Accepted

- **Save granularity coarsens 16×** (4KiB → 64KiB): a one-byte guest write
  persists 64KiB at snapshot. For build/save workloads this is noise; for a
  hypothetical high-frequency-save workload it would matter. Accepted;
  revisit chunk size only with a real consumer and a benchmark.
- **Flag-day format break**: old saved spores and caches are dead. Accepted
  by decision; the break is batched into one release with loud notes rather
  than dribbled.
- **GC becomes mandatory infrastructure** before the payoff slices.
- **Runtime map memory**: ~1MiB per 8G disk. Negligible.
- **Migration risk**: run/resume/save/import all change under one plan.
  Mitigated by slice ordering below — each slice keeps `mise run test` green
  and ships a working system.

## Delivery Strategy

This plan is the active storage workstream and has no prerequisites from
other plans. `docs/plans/spore-build.md` is **deferred** (re-sequenced
2026-07-08): this plan's import improvements — U4's inline chunk emission
from the native ext4 writer and U7's partial materialization — shrink the
buildx→import-tar boundary that motivated `spore build` in the first place,
so the builder is revisited only if that boundary still hurts after U4/U7
land. Dirty tracking and incremental index maintenance — previously drafted
as a separate plan — are built here, inside U2 (map-is-dirty-state backend)
and U3 (shared sealer + `snapshot()`).

Quiesce scope for U3: v1 `snapshot()` runs only at the existing capture/save
quiesce points, where the VM is paused and virtio-blk writes are drained —
the same coherence point dirty-RAM sealing uses today (`capture.zig` seals
the final dirty set at capture time). An online mid-run snapshot (guest
`fsfreeze` + VMM drain while the VM keeps running) was a spore-build M2
requirement and defers with that plan; nothing in U1–U8 needs it.

### U1 — Unified index type and CAS GC

Status: landed in branch.

Rename/promote `rootfs-block-index-v0` to `spore-disk-index-v1` (one parser,
shared by all consumers); implement mark-sweep `spore cache gc` over the
chunk store with roots enumerated from refs/records/manifests.

Landed behavior: existing chunked-rootfs producers now write
`spore-disk-index-v1` through `src/disk_index.zig`; restore, bundle, pull, and
CAS preload all validate through that parser. The parser rejects
`rootfs-block-index-v0` as too old after the flag-day break, so pre-U1 cache
entries are abandoned rather than migrated. `spore cache gc` performs a
dry-run-by-default mark/sweep over rootfs CAS indexes and objects, rooting
descriptor-selected indexes from cache metadata, ref records, and live runtime
resume manifests.

Validation: `mise run test` covers index parser/fuzz coverage and a GC model
test that preserves a rooted index/object pair while deleting an unrooted index,
its object, and a stray object.

### U2 — Chunk-mapped runtime backend

Status: landed in branch.

Implement `ChunkMappedDisk`; switch normal `spore run` (currently
`file`+`CowDisk`) to it. `layered_cow` still exists for old saves during
this slice only.

Landed behavior: fresh runtime disks now use `src/chunk_mapped_disk.zig`, a
one-level 64KiB chunk map over the flat materialized base and an optional sparse
overlay. Manifest-backed writable rootfs runs, layerless saved disks, and direct
read-only rootfs attachments all enter virtio-blk through the chunk-mapped
backend. During U2, `LayeredCowDisk` remained only for pre-U3 saved disks; U3
deleted that legacy parser/backend and replaced layer sealing with
`snapshotIndex()`.

Validation: `mise run test` covers virtio-blk against the chunk-mapped backend,
runtime CAS materialization paths through the new backend, read-only write
rejection, zero-source reads, and the unaligned read-modify-write model ported
from `cow_disk.zig`.

### U3 — Snapshot operation and save/restore switch (format break)

Status: complete in branch.

Extract the shared `chunk_sealer.zig` core from `dirty_ram.zig` (RAM path
refactored onto it, behavior-identical); implement `snapshot()` on that
core; cut `spore save` to emit index + chunks + v2 manifest; cut
restore/resume to open indexes. Delete `LayeredCowDisk`, layer chains,
`spore.DiskLayer`.

Landed behavior: RAM sealing and disk snapshotting share
`src/chunk_sealer.zig` for zero elision, BLAKE3 chunk identity, and verified
write-if-missing CAS publication. `ChunkMappedDisk.snapshotIndex()` retains
the parent index for index-opened disks, seals only overlay-backed dirty chunks
when publishing into the same CAS root, writes nonzero dirty chunks and a
`spore-disk-index-v1` under the rootfs CAS namespace, and returns a
`chunk-index-disk-v0` manifest disk. Disks opened without a parent index, or
snapshots published into a different CAS root, keep the full-scan snapshot
path. Runtime restore materializes `chunk-index-disk-v0` manifests from the
saved index and chunk objects before attaching virtio-blk; old layer chains are
no longer opened by `runtime_disk.open`. `LayeredCowDisk`, `loadLayerChain`,
disk-layer sealing, and the `spore.DiskLayer` parser have been deleted.

Validation: `mise run test` covers the RAM sealer on the shared core, direct
disk snapshot index/object emission, and runtime restore of a chunk-index disk
manifest preserving guest-visible bytes. `src/chunk_mapped_disk.zig` also
compares O(dirty) snapshot output from an index-opened fork chain against a
full rescan of the materialized image, including dirty zero chunks and chunks
rewritten back to their parent content, and asserts the sealer work count
matches the dirty chunk count rather than total logical chunks.

Done when: save→restore round trip preserves guest-visible disk state
(existing lifecycle tests, rewritten for v2); the RAM sealer's existing
tests (including `dirty_ram.zig`'s corrupt-chunk rejection) pass unchanged
on the shared core, and disk `snapshot()` has no sealing loop of its own;
v0/v1 spores fail closed with a clear "format too old" error; the deleted
code is gone, not flagged off; `docs/spore-format.md` documents v2 and the
break.

### U4 — Identity flag-day

Status: landed in branch for the existing rootfs build/import and image-save
paths. The code path now uses rootfs storage index identity for build/import
metadata, rootfs artifacts with `rootfs.storage`, by-digest flat
materialization cache keys, and CLI/API rootfs output. `rootfs_blake3`,
`ensureImageRootfsStorage`, the flat metadata upgrade path, and the native
writer's unused flat-image digest have been removed from the rootfs build path.

`H(index)` everywhere: import produces indexes (native writer inline or
full-scan fallback), by-digest cache re-keys, refs/metadata carry index
identity, `rootfs_blake3` and `ensureImageRootfsStorage` deleted.

Landed behavior: the native ext4 writer now streams emitted bytes through an
inline rootfs CAS/index writer for chunked storage. It records zero chunks
without materializing them, hands nonzero 64 KiB chunk copies to a bounded
sealer worker pool, writes missing objects durably with race-safe temp+link
publication, and publishes the rootfs `spore-disk-index-v1` after every worker
has joined successfully. The external writer keeps the full-scan
`rootfs_cas_preload` fallback.

Validation: `src/rootfs/ext4_writer.zig` compares the inline-maintained
`H(index)` with a materialized file rescanned by `rootfs_cas.preloadPath` and
forces the inline path through two seal workers. `src/chunk_sealer.zig` covers
same-digest CAS object publication races. `docs/plans/native-ext4-writer.md`
records the large-tar import benchmark against the external preload baseline;
the 2026-07-08 rerun on the documented 312 MiB tar cut `rootfs_cas_inline`
from 3.392s serial to 1.545s with 8 seal workers.

Follow-up benchmark on latest `main` after PR #421, commit
`7a031e9c205f7f9aa7f31c0205a6d31a043e99b3`, showed the large
buildkite-sporevm image still importing in roughly the same time as #420, but
regressed warm `spore run --image ... -- /bin/true` from about 0.38s to
1.73-1.76s. The extra wall time was before guest ready
(`vsock_connect_ms=17`, `exec_response_ms=33`) and came from walking the
complete 74k-object CAS index on flat-hot run setup. The follow-up fix writes a
digest-keyed `complete` stamp when rootfs CAS sealing finishes, makes cached
image/ref resolution check that stamp plus the index instead of statting every
object, and has GC/prune remove stamps before deleting an index or referenced
object. The prevalidated run path also skips its duplicate completeness check.
On an exact rebuild/import through `buildkite-sporevm/bin/buildkite-spore` with
this branch's ReleaseSafe binary, warm
`spore run --image local/buildkite-spore:dev -- /bin/true` measured
`real=0.10s user=0.08s sys=0.01s`.

The same exact buildkite-sporevm import rerun added the native emit split:
`native_ext4_emit ms=94139 plan_ms=214 assign_ms=73834 metadata_build_ms=176
file_create_ms=1 emit_map_ms=48 metadata_write_ms=793 source_read_ms=1688
data_write_ms=4754 zero_ms=7 zero_write_ms=0 inline_cas_metadata_ms=204
inline_cas_data_ms=11840 inline_cas_zero_ms=3 inline_cas_finish_ms=42
file_sync_ms=0 file_close_ms=16 metadata_blocks=44384 data_blocks=1149892
zero_blocks=751324 metadata_bytes_written=181796864
data_bytes_written=4709957632 zero_bytes_skipped=3077423104`.
`rootfs_cas_inline` for the same run was `ms=94139`, `seal_workers=8`,
`seal_wall_ms=19337`, and `seal_worker_cpu_ms=77342`. The main-thread problem
is therefore block assignment/metadata planning, not tar reads or writing zero
blocks; zero ext4 blocks are skipped on the output path.

Done when: import → run → save → restore works end to end on index identity
with no linear full-image hash anywhere; uncached import of a large
reference image pays no separate hash pass beyond the inline emission
(measured against the native-writer baseline in
`docs/plans/native-ext4-writer.md`); a repeat import / cached
`spore run --image` of an unchanged image still resolves in <1s; equivalence
test proves `H(index)` of a materialized-then-rescanned file matches the
maintained value.

### U5 — Memory index parity (format break, batched with U3/U4's)

Status: complete in branch.

Converge `MemoryManifest` onto the unified index type: the dense
optional-ref array becomes a `spore-disk-index-v1`-shaped value (sparse
extents + zero list, `chunk_size` field already exists) parsed by the one
shared parser; `memoryFingerprintHex` is replaced by the same canonical
index hash disk uses. RAM keeps its 2MiB chunk size — granularity stays a
parameter, not a casualty of parity. The `ram.backing` acceleration path
and HMAC proof are untouched except that the fingerprint they bind to is
now the index identity.

Sequenced immediately after U4 and shipped in the same release, so the
manifest format breaks exactly once; the disk side (U3/U4) proves the shape
first.

Done when: one index parser and one index-hash function serve RAM and disk
(grep-level assertion: no `MemoryManifest`-specific chunk-list parsing
left); save→fork→resume round trips pass on the converged encoding; the
backing-proof path binds to the new identity and its existing
tamper-rejection tests pass; `docs/spore-format.md` describes one index
structure with two instantiations (RAM 2MiB, disk 64KiB).

### U6 — Fork

Status: landed in branch for the disk backend.

Implement ephemeral `fork` on `ChunkMappedDisk` (map copy + overlay reflink
per the Design section), with a plain dirty-chunk overlay-copy fallback for
hosts without reflink. Durable child creation needs no new code — it is
`snapshot()` + open, which exists after U3. Expose `fork` wherever the
VM-level fork operation lands; this slice owns only the disk side.

Landed behavior: writable `ChunkMappedDisk` instances can now create a
`ForkedDisk` by copying the in-memory chunk-source map and giving the child an
unlinked temp overlay cloned from the parent's overlay. Linux hosts attempt
`FICLONE`; other hosts or explicit `force_copy` use a plain dirty-chunk copy
fallback. The primitive asserts its caller has quiesced the VM and has no
in-flight virtio-blk requests before cloning mutable disk state. Read-only
disks reject `fork`, and durable child creation remains `snapshot()` + open.

Validation: `mise run test` covers read-only rejection, forced-copy fallback,
parent/child divergence, and a 32-deep sequential fork chain that keeps the
chunk map flat and avoids parent contamination.

Done when: fork of a running writable disk completes in O(map copy) —
target <100ms for an 8G disk regardless of dirty volume on a reflink-capable
host; a chain of N sequential forks shows no read-latency growth
(property/benchmark test, N ≥ 32); parent and child diverge without
cross-contamination (existing COW divergence tests, generalized); the
no-reflink fallback path is exercised in tests.

### U7 — Partial materialization

Status: complete for local CAS fault-in and measured cold-flat startup.

Add the `.cas` map source, fault-in path, background filler, and
boot-critical chunk ordering (fault-trace a reference boot to derive the
priority set).

Landed behavior: chunk-index disks and chunked rootfs caches can now open over
a sparse temporary base fd without assembling the full flat image first. The
chunk map marks nonzero index entries as `.cas`; the first read of a CAS chunk
opens the local object, verifies it against the descriptor-selected BLAKE3
digest, writes it into the sparse base, and promotes that map entry to `.base`.
Missing or corrupt objects fail the read before bytes reach the guest. Warm
flat-cache opens still use the existing read-only materialization path.
Managed `spore run --image` resolves chunked image-rootfs storage even without
`--save`, and cache lookup no longer repairs an evicted flat by-digest
materialization as a side effect, so a warm-CAS/cold-flat image run reaches the
lazy runtime path.

Decision: a concurrent background filler and boot-critical priority list are
deferred until fault traces show they are needed. Adding a filler now would
require synchronization around the hot chunk map and would reintroduce eager
whole-image work in another form. The guest's actual read stream provides the
correct initial ordering for this slice.

Validation: `mise exec -- zig test src/runtime_disk.zig` covers lazy rootfs
open without publishing a flat cache, wrong-sized flat-cache fallback, CAS
promotion after the first read, read-time missing-object failure, induced
eviction of an already promoted chunk, corrupt unread-object failure without
torn read data, and chunk-index disk restore over the lazy backend. The same
test graph also drives virtio-blk descriptor chains over a lazy chunk-mapped
disk for missing-object and same-size corrupt-object reads: both complete the
request with `status_ioerr`, advance the used ring, leave the failed read
buffer unchanged, and then serve a promoted healthy chunk on the same queue.

Repeatable time-to-first-exec measurement lives in
`scripts/benchmark/suite.py` as the opt-in `lazy_rootfs_tti` benchmark. The
benchmark reports three rows per iteration:

- `lazy-cold`: evict flat materializations and boot through lazy CAS fault-in.
- `eager-cold`: restore, evict, then set the internal
  `SPOREVM_ROOTFS_EAGER_MATERIALIZE_FOR_BENCHMARK=1` escape hatch so
  `spore run --image` eagerly materializes the flat artifact from warm CAS
  before boot.
- `flat-hot`: reuse the hot flat materialization as the overhead baseline.

Command used for the local U7 check after `mise run build`:

```sh
python3 scripts/benchmark/suite.py --profile smoke --benchmarks lazy_rootfs_tti --iterations 1 --modes sequential --output-dir zig-cache/sporevm-benchmarks/u7-lazy-rootfs-followup --timeout-s 300 --no-build
```

On this macOS/HVF host with `docker.io/library/node:22-alpine` resolved to
`docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271`,
the run at
`zig-cache/sporevm-benchmarks/u7-lazy-rootfs-followup/20260708T124036Z-c9b041e2/`
used the CI-runnable 512 MiB flat image and measured:

- `lazy-cold`: evicted one 512 MiB flat materialization,
  `rootfs_base_mode=lazy`, `tti_ms=454`, `first_output_ms=283`.
- `eager-cold`: restored and evicted one 512 MiB flat materialization,
  `rootfs_base_mode=flat`, `tti_ms=1567`, `first_output_ms=33`.
- `flat-hot`: reused the hot flat materialization,
  `rootfs_base_mode=flat`, `tti_ms=182`, `first_output_ms=38`.

The small node image validates the repeatable benchmark and CI-friendly
assertions. The meaningful asymptotic demonstration is a large image such as
the approximately 7.4 GiB `buildkite-sporevm` rootfs: with warm CAS and evicted
flat materializations, `lazy-cold` should stay bounded by the boot working set
while `eager-cold` scales with full flat materialization. Run it by hand with:

```sh
python3 scripts/benchmark/suite.py --profile smoke --benchmarks lazy_rootfs_tti --iterations 1 --modes sequential --image <large-image-ref> --output-dir zig-cache/sporevm-benchmarks/u7-lazy-rootfs-large --scratch-dir zig-cache/sporevm-benchmarks/u7-lazy-rootfs-large-scratch --timeout-s 900
```

Done when: complete for the local lazy path, virtio-blk error completion, and
repeatable lazy/eager/flat TTI measurement. Cold-flat startup is bounded by the
boot working set, not full image assembly; the measured lazy run starts the
guest before restoring or rebuilding the 512 MiB flat materialization, while
the eager-cold baseline pays full materialization before boot. Background
filler and boot-priority ordering remain deferred until fault traces show they
are needed.

### U8 — Cleanup and docs

Status: landed in branch.

Remove transitional shims, update `docs/rootfs.md`/`docs/filesystem.md`
architecture sections, SECURITY.md parser inventory (net reduction: three
index parsers → one), release notes covering the format break and the new
boot/fork behavior.

Landed behavior: the unused public `CowDisk` backend and virtio-blk `.cow`
backend arm are gone; writable COW behavior now lives only inside
`ChunkMappedDisk`. Durable filesystem, rootfs, state-portability, security, and
release-note docs describe disk indexes, lazy CAS fault-in, the format break,
and the fork/runtime behavior.

Validation: `mise run test` and `mise run build`.

## Security

- Net parser reduction: the `DiskLayer` parser is deleted, and writable disks
  now use the hardened `DiskIndex` parser. Restore-authority surface shrinks.
- The chunk map is host-internal state derived from validated values; the
  virtio-blk request parsing is untouched (frozen device model).
- CAS objects remain verify-at-write, trust-at-open; index digests bind
  coverage and size exactly as `validateDiskIndex` does today.
- GC is a new destructive operation: it must be root-conservative (unknown
  record kinds are roots, not garbage) and tested against concurrent-ish
  root creation (lock protocol test).
- The snapshot freeze/drain must produce clean images, never
  crash-consistent guesses. In v1 this is satisfied structurally: snapshots
  run only at capture/save points where the VM is paused and virtio-blk
  writes are drained. An online mid-run snapshot would need the guest
  `fsfreeze` protocol deferred with the spore-build plan.
- Partial materialization (U7) puts CAS object reads on the guest I/O path
  for the first time: objects are digest-verified at fault-in before bytes
  reach the guest, and missing/corrupt objects surface as clean I/O errors
  to the guest, never hangs or silent zero-fill. U7 tests cover promoted
  chunk eviction and corrupt unread objects.

## Resolved Decisions

- This plan is the storage/runtime architecture for fast boot and fast fork,
  not a standalone simplification: fork and partial materialization are
  in-plan milestones (U6, U7), not extensions.
- Memory/disk parity is in-plan, not aspirational: RAM is the reference
  implementation of the model, disk adopts its sealer (shared core, U3) and
  its identity scheme, and memory adopts the unified index encoding (U5).
  Chunk granularity stays per-domain (RAM 2MiB, disk 64KiB). Only store
  unification remains open.
- Flat materialization stays the hot steady-state read path; the CAS is
  read per-chunk only during U7 fault-in, and each faulted chunk is
  promoted into the materialization so it is read from the store at most
  once.
- 64KiB wins the granularity merge (matches CAS; save coarsening accepted).
- One-level map, never stacks: restore of a deep snapshot lineage costs the
  same as a fresh image boot.
- Flag-day break over bilingual transition: the dual-identity/dual-namespace
  machinery drafted in the deleted incremental-index direction is explicitly
  *not* built.
- GC before deletion: no slice that removes an old mechanism lands before
  `spore cache gc` exists.
- Durable-index invariant: an index is only written once every chunk it
  references is durable in a store. Consequence for the deferred
  `spore build` plan, should it be revived: intermediate step checkpoints
  are local flat clones with no index; only the final snapshot writes
  chunks + index.
- Fork and durable-child are two named operations, not one configurable
  mechanism: `fork` = map copy + overlay reflink, ephemeral, no identity;
  durable children come from `snapshot()` + open. Reflink is a host-fs
  capability with a defined fallback (snapshot-then-open), not an
  assumption.

## Open Questions

- Chunk object packing (many small files vs packfiles). File-per-chunk
  ships through U6: RAM already runs file-per-chunk at 2MiB without
  trouble, and incremental snapshots mostly skip writes via
  write-if-missing, so the snapshot write path is expected to be fine. The
  access pattern that could force packing is U7 fault-in — an
  open+read+close per 64KiB miss on cold boot (~70K objects for the
  reference image). Decide at U7 with fault-trace data in hand; do not
  build packfiles speculatively, since file-per-chunk is what keeps
  write-if-missing dedupe and unlink-based GC trivial. The index format is
  unaffected either way.
- Whether RAM and disk chunks should eventually share one *store*. This
  plan closes the code/format gaps (shared sealer in U3, shared index
  encoding and identity in U5, granularity as a parameter — RAM 2MiB, disk
  64KiB); what stays open is the store split: memory chunks in per-spore
  `chunks/` directories with a portable bundle lifecycle, disk chunks in
  the machine-global CAS with a cache/GC lifecycle. The forcing case is
  `spore save` of a VM booted from an image: its disk index is ~mostly the
  image's chunks, already in the global CAS, and copying gigabytes into
  every spore directory at save time is waste. Sketched direction:
  **complete-on-export, not complete-on-save** — a local bundle's index may
  reference global-CAS chunks (GC roots already enumerate manifests, so
  they stay protected), and an explicit `spore export` copies chunks in to
  make the directory self-contained and portable. Adopt when that save
  path becomes real; the U1 namespace choice must not preclude it.
