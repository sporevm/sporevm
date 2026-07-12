---
status: active
last_reviewed: 2026-07-12
spec_refs:
  - docs/spore-format.md
  - docs/rootfs.md
  - docs/filesystem.md
  - SECURITY.md
  - src/spore.zig
  - src/api.zig
  - src/bundle.zig
  - src/disk_layer.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/runtime_disk.zig
  - src/runtime_disk_claim.zig
  - src/runtime_disk_fork.zig
  - src/runtime_disk_fork_control.zig
  - src/runtime_disk_lease.zig
  - src/saved_spore_pin.zig
  - src/snapshot_publication.zig
  - src/dirty_ram.zig
  - src/monitor.zig
  - src/lifecycle.zig
  - src/system.zig
  - src/hvf/vm.zig
  - src/kvm/vm.zig
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

> **Current state (2026-07-11): U7 is complete.** Disk-backed
> `spore fork --vm` now uses the live monitor/VMM quiescence boundary, one-use
> fd claims, independently rooted child baselines, and readiness-after-adoption.
> The maintained product smoke and native clone path pass on APFS/HVF and on a
> real ARM64 Linux/KVM host. U7 lazy runtimes now root their CAS storage for the
> complete named-monitor or foreground-run lifetime. Dense-image fault traces
> do not justify a background filler, boot-priority list, or packfiles, and show
> no latency urgency for index compaction. RAM/disk store convergence remains a
> separate follow-up, not incomplete U6 implementation.

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

Left alone, this would have got worse before better: the original `spore
build` design proposed a third write-persistence model (write-in-place +
reflink checkpoint), and the obvious incremental fix — maintaining the
existing `rootfs-block-index-v0` with a new virtio-blk dirty bitmap and a
dual-identity transition — would have added a second dirty tracker and a
second identity namespace on top. The revived builder instead consumes the
unified snapshot primitive from this plan.
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
  their output through it, as do `spore build` step checkpoints.
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
  their own "done when" measurements). The native Dockerfile builder and its
  cached-rebuild target remain owned by `docs/plans/spore-build.md`; this
  plan's local-iteration wins are fast import (U4: inline chunk emission, no
  separate full-image hash), fast cold start (U7: partial materialization),
  and the disk side of live named fork (U6).
- No cross-machine chunk distribution. The unified store and lazy fault-in
  make a remote chunk source natural later; building it is separate work.
- No new memory-state fork mechanism. U6 reuses the already-landed named-fork
  RAM/machine capture and per-child identity transformations; this plan owns
  only replacement of that flow's diskless restriction with a fast disk head
  (see Open Questions on namespace convergence).
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
                       | .overlay_clean (saved bytes in sparse local overlay)
                       | .overlay (dirty bytes in sparse local overlay)
                       | .zero
                       | .zero_dirty
                       | .cas (verified object fault-in)
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
  map from the parent's, give the child a private reflink clone of the
  parent's overlay (APFS clone or Linux `FICLONE`, effectively O(1)), and
  resume both. The clone becomes the child's writable overlay, so subsequent
  writes diverge without adding a source layer. No durable identity is
  produced; this is the fast-fork product primitive for fan-out. Still one
  map lookup per read — sources are fds, not a stacked chain.
- **`snapshot` + open** (durable): run `snapshot()` on the parent (O(dirty)
  hashing), open the resulting index for the child. Costs the hash, yields
  an identity — for lineage, caching, and publishing.

Reflink is a host-filesystem capability (APFS, XFS, btrfs), not a universal
one. The production fast-fork command fails closed when a native clone is
unavailable unless the caller explicitly opts into the slow dirty-chunk copy
path; tests can force that path. `snapshot()` + open remains the separate
durable operation. A defined fallback, not an assumption.

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
                virtio-blk drained; online build checkpoints additionally use
                the spore-build guest-fsfreeze protocol)
  for each dirty entry: blake3 chunk, write CAS object if absent
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
self-contained prior identity to preserve in that destination store. A
successful snapshot advances the logical parent digests and marks dirty
overlay/zero entries clean, but never rebinds live physical reads to the
snapshot output CAS. This matters for snapshot-and-continue: lifecycle may
rename the output directory as soon as publication completes, while the VM
must continue reading its already-open base and overlay fds. The
operation already exists in the tree for RAM: `dirty_ram.zig` seals dirty 2MiB
memory chunks into verified chunk refs plus a same-host backing file, with
parallel workers, zero-scan elision, write-if-missing dedupe, and phase-level
stats.
Disk does not duplicate the sealing and publication primitives: U3 extracts
the generic core out of `dirty_ram.zig` into `chunk_sealer.zig`, with
RAM-specific backing/proof work and disk-specific dirty-map traversal staying
in their domain modules. RAM and disk retain separate traversal loops because
their source and lifecycle semantics differ, while zero classification, chunk
identity, durable CAS publication, and work accounting stay shared.

One invariant governs all producers: **an index is only ever written once
every chunk it references is durable in a store.** "Index exists" always
means "openable and GC-rootable"; there are no half-durable states for the
parser, restore, or GC to reason about.

Consumers:

- `spore save`: snapshot, then write a manifest referencing the index
  identity. Restore = open the index (materialize if needed), attach. No
  layer chains, no newest→oldest resolution, no `loadLayerChain`.
- `spore build`: each instruction checkpoint uses the same O(dirty)
  `snapshotIndex()` operation and records the resulting child index only after
  all referenced chunks are durable. The final local image ref binds that
  index identity plus canonical image configuration; no terminal full-image
  hash is needed.
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

All planned implementation slices are complete. U6, production
disk-backed named fast fork, is proven on APFS/HVF and by the maintained
product smoke on a reflink-capable Linux/KVM host. Its platform evidence is
complete, with no prerequisite from the remaining evidence-gated U7 follow-ups
or the open store/packing questions.
`docs/plans/spore-build.md` was revived after the unified storage primitives
landed and now consumes them as a separate active workstream. Dirty tracking
and incremental index maintenance — previously drafted as a separate plan —
live here, inside U2 (map-is-dirty-state backend) and U3 (shared sealer +
`snapshot()`).

Quiesce scope for U3: v1 `snapshot()` runs only at the existing capture/save
quiesce points, where the VM is paused and virtio-blk writes are drained —
the same coherence point dirty-RAM sealing uses today (`capture.zig` seals
the final dirty set at capture time). `spore build` subsequently added its
guest-`fsfreeze` checkpoint protocol in its own plan. U6 uses a different
operation: it pauses the complete VM, captures RAM/machine state and every
child disk head at one VMM-owned queue-drained epoch, then resumes the source.
It must not call the durable disk sealer on the fast-fork path.

### U1 — Unified index type and CAS GC

Status: landed.

Rename/promote `rootfs-block-index-v0` to `spore-disk-index-v1` (one parser,
shared by all consumers); implement mark-sweep `spore cache gc` over the
chunk store with roots enumerated from refs/records/manifests.

Landed behavior: existing chunked-rootfs producers now write
`spore-disk-index-v1` through `src/disk_index.zig`; restore, bundle, pull, and
CAS preload all validate through that parser. The parser rejects
`rootfs-block-index-v0` as too old after the flag-day break, so pre-U1 cache
entries are abandoned rather than migrated. All persisted producers share one
canonical encoder, and parsing requires the input to match that exact field
order, indent-2 JSON layout, lowercase digest spelling, and no-final-newline
encoding. `spore cache gc` performs a
dry-run-by-default mark/sweep over rootfs CAS indexes and objects, rooting
descriptor-selected indexes from cache metadata, ref records, and live runtime
resume manifests. Valid build step records also root their child index and
objects; known incomplete records remain cache misses, while unknown future
record kinds conservatively retain the whole CAS. Builds take the coarse rootfs
cache lock after resolving `FROM` and hold it through cache lookup and execution,
so GC cannot sweep objects between step snapshot publication and the durable
record that roots them. Bundle pack and unpack/pull also hold the lock while
reading, regenerating, or publishing shared rootfs CAS state. Unpack/pull
validates declared payload totals before mutation, installs verified objects
before publishing the index, and writes the completeness stamp only after the
whole storage value is durable. Both mark/sweep GC and legacy cache prune hold
the same lock across planning and deletion, so neither can select in-flight
publication for removal.

Validation: `mise run test` covers index parser/fuzz coverage and a GC model
test that preserves a rooted index/object pair while deleting an unrooted index,
its object, and a stray object. A golden byte/digest test pins canonical index
serialization, and parser/fuzz regressions reject compact, reordered, or
uppercase-digest aliases even when their descriptor names their raw bytes.
Build-cache GC tests preserve a step-record-only root and its subsequent cache
hit, ignore a known incomplete record, and retain all CAS entries for an unknown
build-record kind. Bundle tests prove successful pulls publish a completeness
stamp and a corrupt final object cannot expose an index or stamp for partial
storage.

### U2 — Chunk-mapped runtime backend

Status: landed.

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

Status: complete.

Extract the shared `chunk_sealer.zig` core from `dirty_ram.zig` (RAM path
refactored onto it, behavior-identical); implement
`ChunkMappedDisk.snapshotIndex()` using those shared primitives; cut
`spore save` to emit index + chunks + v2 manifest; cut restore/resume to open
indexes. Delete `LayeredCowDisk`, layer chains, `spore.DiskLayer`.

Landed behavior: RAM sealing and disk snapshotting share
`src/chunk_sealer.zig` for zero elision, BLAKE3 chunk identity, and verified
write-if-missing CAS publication. `ChunkMappedDisk.snapshotIndex()` retains
the parent index for index-opened disks, seals only overlay-backed dirty chunks
when publishing into the same CAS root, writes nonzero dirty chunks and a
`spore-disk-index-v1` under the rootfs CAS namespace, and returns a
`chunk-index-disk-v0` manifest disk. Disks opened without a parent index, or
snapshots published into a different CAS root, keep the full-scan snapshot
path. Snapshot promotion updates the logical parent index while preserving the
live physical source of every chunk; clean overlay bytes remain overlay-backed
rather than faulting through the save output, and grow/explicit-zero mutations
remain dirty until their new logical size/content is published. A clean save
after a prior dirty save republishes the current identity into the new output
instead of returning the runtime's stale initial base descriptor. Runtime
restore materializes `chunk-index-disk-v0` manifests from the
saved index and chunk objects before attaching virtio-blk; old layer chains are
no longer opened by `runtime_disk.open`. `LayeredCowDisk`, `loadLayerChain`,
disk-layer sealing, and the `spore.DiskLayer` parser have been deleted.

Validation: `mise run test` covers the RAM sealer on the shared core, direct
disk snapshot index/object emission, and runtime restore of a chunk-index disk
manifest preserving guest-visible bytes. `src/chunk_mapped_disk.zig` also
compares O(dirty) snapshot output from an index-opened fork chain against a
full rescan of the materialized image, including dirty zero chunks and chunks
rewritten back to their parent content, and asserts the sealer work count
matches the dirty chunk count rather than total logical chunks. Snapshot-state
regressions cover continuing after output publication/rename and repeated clean
saves retaining the latest disk identity.

Done when: save→restore round trip preserves guest-visible disk state
(existing lifecycle tests, rewritten for v2); the RAM sealer's existing
tests (including `dirty_ram.zig`'s corrupt-chunk rejection) pass unchanged
on the shared core, and disk `snapshot()` uses the shared classification and
durable-publication primitives while keeping its dirty-map traversal local;
v0/v1 spores fail closed with a clear "format too old" error; the deleted
code is gone, not flagged off; `docs/spore-format.md` documents v2 and the
break.

### U4 — Identity flag-day

Status: complete for the existing rootfs build/import and image-save
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
the resulting ReleaseSafe binary, warm
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
blocks; zero ext4 blocks are skipped on the output path. Follow-up after the
run-image readiness PR lands: profile inside `assignBlocks` for O(n^2) behavior
or allocation churn over the roughly 2M-block buildkite image before doing any
more sealer work.

Follow-up result: the assignBlocks hotspot was the directory emission path
scanning every planned path for every directory on high-directory-count images.
The ext4 writer now builds a conditional direct-child index for large
directory/path topologies, keeps source data block mappings as contiguous runs,
and allocates payload block slices in batches. On the buildkite-sporevm rootfs,
`assign_ms` fell from roughly 73-80s to 304ms (`emit_map_ms=76`,
`native_ext4_emit_ms=88957`) with the remaining cold import time dominated by
inline CAS sealing/object writes rather than block assignment.

Done when: import → run → save → restore works end to end on index identity
with no linear full-image hash anywhere; uncached import of a large
reference image pays no separate hash pass beyond the inline emission
(measured against the native-writer baseline in
`docs/plans/native-ext4-writer.md`); a repeat import / cached
`spore run --image` of an unchanged image still resolves in <1s; equivalence
test proves `H(index)` of a materialized-then-rescanned file matches the
maintained value.

### U5 — Memory index parity (format break, batched with U3/U4's)

Status: complete.

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

### U6 — Production disk-backed fast fork

Status: complete; APFS/HVF and Linux/KVM product validation pass.

`ChunkMappedDisk.exportForkHead()` copies the one-level source map and either
clones an unlinked overlay fd when physical overrides remain or creates a fresh
sparse fd when the exact committed baseline owns all clean state. Its unit tests cover
rejection, copy fallback, sparse baseline reads, divergence, and flat
32-generation lineage. Disk-backed `spore fork --vm` is now its production
caller. Diskless children retain the existing durable snapshot-and-open flow;
disk-backed children use runtime heads and never seal dirty disk chunks before
resuming the source.

Landed behavior supports image-created, explicit-rootfs, restored disk-index,
and previously forked named VMs with exactly one writable rootfs device. The
source monitor prepares up to 32 heads at one queue-drained paused epoch. Each
child receives only a transient claim, independently reopens the lease-bound
baseline, adopts its fd before readiness, and can outlive the source, fork
again, or publish a durable save. Networked and unsupported device layouts
remain fail-closed. Native APFS/Linux cloning is the default when physical
overrides remain; the full-overlay copy path requires the explicit
`--allow-slow-copy`/Zig API opt-in. Once save publication commits the exact
canonical baseline, clean overlay and zero state are baseline authority rather
than child overrides, so an override-free fork mints fresh sparse heads on any
filesystem. `sparse` is an internal runtime descriptor method and does not
change the durable spore format.

The first product boundary is the existing named live-fork command with one
supported writable rootfs-bound `ChunkMappedDisk`. It covers image-created,
explicit `--rootfs`, restored disk-index, and previously forked named VMs. A
child is ephemeral runtime state until an explicit `spore save` gives it a
durable disk identity; it can diverge, fork again, and be saved/restored
normally. Networked fork and unsupported device layouts remain fail-closed.

#### Runtime state model

U6 reuses the existing named-fork RAM/machine capture; it does not add a new
RAM fork algorithm. The fork-specific hidden capture is runtime-only: it
contains the shared RAM, machine, device, and rootfs metadata needed to start
children, but does not call `SnapshotState.finish()` or pretend that the
parent's dirty disk has acquired a durable manifest identity. Normal
`spore open`/restore must reject or never observe this incomplete internal
record.

After the shared capture, every child still receives the transformations that
`spore.fork` applies today: generation-device and GIC fork state, fork batch
and child index, VM identity, hostname, and MAC. Extract/reuse that logic rather
than resuming siblings from byte-identical machine identity.

Index identity alone is not read authority. Every child lifecycle record also
owns a host-private baseline lease for the exact immutable rootfs/index and
object root from which non-overridden chunks are reopened. A global-cache
lease is a GC/prune root; a restored-spore lease points at stable saved-spore
storage, never the source VM's runtime or fork-batch directory. The lease is
independent of the source monitor, survives source removal, is inherited by a
nested fork, and is released only when the child stops or publishes its own
durable save and atomically adopts the new authority. If that lifetime cannot
be pinned, fork fails before the source resumes; children never reopen from an
identity with no live store authority.

#### Coherence and handoff contract

The source monitor owns the live disk pointer and overlay fd, so lifecycle
must not call `ChunkMappedDisk.fork()` directly. Add a fork-specific VMM
control action with these invariants:

1. The VMM thread pauses every vCPU and proves the virtio-blk queue has no
   in-flight request. It captures machine/RAM state once and creates all N
   disk heads from that same paused epoch, without calling the durable disk
   sealer.
2. Each head contains one unlinked overlay fd and a bounded, same-version
   runtime descriptor: exact baseline lease/identity, logical size, chunk
   size/count, clone method, a physical-overlay bitmap, and a logical-zero
   bitmap. Against an older or uncommitted baseline these conservatively include
   `overlay_clean` and clean `zero` state. Against the exact committed baseline,
   only dirty physical/zero overrides remain; an empty physical bitmap permits
   the private `sparse` method. All other chunks are reopened through the bound
   baseline lease. Extra rehashing on a later save is acceptable, lost state is
   not.
3. A child monitor applies the existing exec-deny jail, reads its lifecycle
   spec, then claims exactly one descriptor and one fd directly from the
   source monitor over a private Unix socket using `SCM_RIGHTS`. The claim is
   bound to a random one-use token, batch, child name/index, and baseline
   identity. The jail is neither weakened nor reordered.
4. Before adoption, the receiver rejects truncated ancillary data
   (`MSG_CTRUNC`), missing or multiple fds, and descriptors whose two bitmaps
   are not exact-length, disjoint, and zero-padded past the final chunk. The
   sole fd must be a regular file of the exact logical size, open `O_RDWR`
   without append semantics; set `FD_CLOEXEC` immediately on receipt. Only
   then may `RuntimeDisk` adopt it.
5. The child fully reopens and validates the bound baseline, applies the two
   override maps, and owns its `RuntimeDisk` before publishing `ready.json`.
   Lifecycle must never report a child ready before a failed claim or baseline
   open can surface.
6. The source owns each head until a successful fd transfer; the child has one
   owner after adoption. Cancellation, expiry, source shutdown, CLI timeout,
   and partial child startup close every unclaimed fd. Rollback tracks monitors
   that spawned but did not reach ready, not only earlier ready children. The
   source VM resumes after the batch is published or rolled back, even when
   child startup later fails.
7. The first disk-backed product limit is 32 children per batch, 4KiB total
   rendered child-name bytes, 2MiB per descriptor, and 64MiB aggregate
   descriptor payload, checked before allocation. Batch prepare/cancel and the
   indexed claim request stay within the existing 8,192-byte JSON control
   bound. Bitmap payloads do not use that line parser: after a small validated
   claim header, the private socket switches to a fixed-version binary frame
   with an exact descriptor length and the overlay fd attached once to the
   first frame. The receiver rejects short reads, trailing bytes, or a second
   ancillary fd. The separate lineage proof remains 32 sequential one-child
   generations.

When physical overrides remain, APFS `fclonefileat` needs a destination name. It may create an `O_EXCL` file
inside a private `0700` directory on the same filesystem as the source
overlay, open it, and unlink it immediately; the overlay factory must preserve
that same-filesystem guarantee. No persistent overlay path or linked child
handoff is permitted. Linux continues to use `FICLONE`. If native cloning of
required overrides is unavailable, production fast fork fails closed unless
the caller explicitly requests the measured slow-copy path. An exact committed
baseline with no physical overrides instead uses a fresh sparse fd.

The baseline binding must survive source history. In particular, a
non-destructive save currently snapshots into a temporary directory and then
renames it while the live backend can retain the temporary `parent_root`.
That stale authority breaks later parent-index reuse and snapshot publication.
Fix or eliminate it before runtime-head export; add
save→rename→fork→save coverage.

#### PR-sized delivery

1. **Fix baseline authority after save.** Make the live backend's post-save
   parent authority stable across lifecycle's temporary-directory rename and
   cover save→rename→snapshot reuse. This is a standalone correctness PR and a
   prerequisite for runtime export. **Complete:** non-destructive save now
   stages lifecycle metadata and save-time annotations beside the snapshot,
   lets the monitor atomically rename the complete spore while the VMM still
   owns the disk head, then transfers the prepared final root into
   `ChunkMappedDisk` without a post-rename allocation. A second incremental
   snapshot test proves parent objects are reused from the final path.
2. **Add a portable runtime disk head.** Add a separate head export/import path
   around an already-open fd and the two bounded override bitmaps; do not force
   the existing in-process `ForkedDisk` to serialize its owned digest tables.
   Add baseline leases, same-filesystem overlay placement, APFS clone plus
   Linux `FICLONE`, explicit slow-copy mode, descriptor unit/fuzz tests, and
   the 8GiB disk-only benchmark. No CLI. **Complete for the head boundary:**
   `RuntimeDisk` now exports and adopts a versioned, bounded descriptor plus an
   owned unlinked fd, validates the independently opened baseline and fd shape,
   uses native APFS/Linux cloning by default for physical overrides, mints a
   fresh sparse head when the exact committed baseline needs no physical
   overrides, and exposes a measured explicit copy fallback. Descriptor
   unit/fuzz coverage and the opt-in 0/50/100% 8GiB benchmark landed with it.
   The lifecycle record that makes the baseline a GC/prune root lands with item
   4, where the record is actually created and can be rollback-tested; the
   descriptor already binds its kind and identity.
3. **Add the one-shot fd-claim transport.** Land `SCM_RIGHTS` send/receive,
   token registry, indexed bounded control requests, exact-length binary
   descriptor framing, receiver validation/ownership, expiry/cancellation,
   and crash cleanup as its own PR. Prove it works after the unchanged monitor
   jail and that adoption precedes readiness. **Complete at the transport
   boundary:** claims are strict 8KiB JSON lines bound to random one-use tokens,
   batch, child name/index, and baseline; registry admission enforces every
   batch/payload cap before ownership moves and closes heads on claim expiry,
   cancellation, or shutdown. The binary response carries one fd on its first
   fixed header and rejects truncation, later ancillary data, short/trailing
   bytes, replay, and binding mismatches. The existing monitor-jail smoke now
   performs the real fd round trip after applying the unchanged jail. Item 5
   owns the readiness-order assertion when child startup consumes this API.
4. **Add the monitor/VMM fork capture.** Keep pause/drain validation
   backend-local in HVF/KVM, but share the request/result and ownership state
   machine. Reuse one RAM/machine capture, prepare all child heads at the same
   epoch, create their baseline leases, and apply the existing per-child
   identity transformations without sealing disk state. **Complete at the
   backend/control boundary:** the bounded internal prepare request now drives
   single- and multi-vCPU HVF/KVM through one paused epoch, separately checks
   the live disk queue (and pending vsock data), writes the shared runtime-only
   RAM/machine capture with no disk manifest, and atomically registers every
   owned head before resuming the source. Errors close partial batches and are
   returned without killing the source. The validated baseline-lease schema is
   now a lifecycle value and protects matching rootfs-cache indexes and objects
   from GC or destructive prune, and exact artifacts from destructive prune.
   Item 5 persists the
   per-child lease and invokes the existing identity transform while consuming
   this internal result.
5. **Enable disk-backed named live fork.** Remove the two disk guards only for
   supported one-rootfs-disk shapes, pass each internal claim to its re-exec'd
   monitor, pre-open its runtime disk, and make batch rollback include
   spawned-but-not-ready children. Add HVF/KVM product smokes, nested fork,
   durable child save/restore, docs, release notes, and lineage benchmarks.
   Keep the network guard. **Complete:** lifecycle now validates and
   roots the source baseline before prepare, consumes the strict prepared
   batch, writes transient child claims only to runtime specs, and rolls back
   monitors that spawned but never became ready. Child monitors claim after
   applying the existing jail, reopen the lease root, adopt before
   `ready.json`, and erase the token from both the live spec and durable spore
   metadata. Save/restore adopts stable saved-spore leases; rootfs GC and
   destructive prune read active leases even in `--rootfs` mode. Monitor exec
   sessions include a random nonce so the first post-fork command cannot
   collide with a source guest's replay cache. The cross-backend product smoke
   covers sibling divergence, identity, nested fork, durable save/restore,
   source deletion, cache GC/prune, and post-prune fork/save. JSON and Zig
   results expose the four phase metrics, and the disk benchmark covers 8GiB
   clone coverage, 32-head preparation, and generation-32 warm reads.

#### Validation and done criteria

- Product smoke: mutate the parent, fork at least two children, verify every
  child inherited the same paused bytes, diverge parent and siblings without
  cross-contamination, fork one child again, then save and restore it. Assert
  distinct generation/GIC state, fork indices, VM IDs, hostnames, and MACs.
- Remove the source VM, run global cache GC/prune, and prove every live child
  can still read untouched and overridden chunks, fork again, and save. No
  child baseline may depend on the source runtime or batch directory.
- Queue-pending injection rejects before cloning, publishes no claim, and
  resumes the source. Partial startup and process exits before/after claim
  leave no fd, token, child-runtime, or batch leaks.
- Protocol tests reject missing/multiple fds, malformed or oversized bitmaps,
  overlapping maps, nonzero padding, ancillary truncation, unknown
  tags/versions, size/chunk-count/baseline mismatches, replayed or cross-child
  tokens, short/trailing binary frames, and non-regular, read-only,
  append-mode, or wrongly sized files. The parser has a fuzz target as required
  for attacker-influenced input.
- Native clone coverage runs on APFS/HVF and reflink-capable Linux/KVM. Forced
  copy requires explicit slow-path opt-in, remains correctness-gated, and
  reports bytes/time, but carries no fast latency promise.
- For `count=1`, preparing one 8GiB disk head from the queue-drained barrier to
  head-ready takes <100ms at 0%, 50%, and 100% physical-overlay coverage on a
  reflink-capable host. At the 32-child cap, disk preparation adds <1s beyond
  the shared RAM/machine capture. Report `ram_capture_ms`, `disk_fork_ms`,
  `source_pause_ms`, and `child_ready_ms` separately; this slice does not
  promise <100ms for the complete `spore fork --vm` command.
- Generation-32 warm random-read p95 is within 10% of generation 0 under the
  same workload, proving lineage never becomes a read chain.
- `mise run test`, `mise run build`, the existing monitor-jail smoke, and the
  real HVF/KVM named-fork smokes pass.

Local APFS/HVF product validation used a 512MiB Alpine guest and produced two
children with `ram_capture_ms=947`, `disk_fork_ms=3`,
`source_pause_ms=950`, and `child_ready_ms=618`. The first command in both
children observed the source's paused bytes; parent and siblings then diverged
independently. Nested fork, non-destructive save/restore, source removal,
forced cache GC plus `--max-bytes 0` prune, post-prune nested fork, and
post-prune save/restore all passed. Repeat with:

```sh
mise run smoke:named-disk-fork
mise run benchmark:disk-fork
```

The local ReleaseFast disk benchmark prepared one native 8GiB head in
`0.774ms`, `3.826ms`, and `3.694ms` at 0%, 50%, and 100% physical-overlay
coverage. Preparing 32 heads at 100% took `19.827ms`. Warm 32,768-read batches
measured `27.389ms` p95 at generation 0 and `27.053ms` at generation 32, a
`0.988x` ratio.

The Linux/KVM path compiles with `zig build -Dtarget=aarch64-linux-musl`. On
AWS instance `i-0e02904c4c1d4d9bf` (`c7gd.metal`, Ubuntu 24.04, KVM), the same
512MiB Alpine smoke produced two native ZFS-backed heads with
`ram_capture_ms=2281`, `disk_fork_ms=37`, `source_pause_ms=2318`, and
`child_ready_ms=1295`; divergence, nested fork, save/restore, source removal,
destructive prune, post-prune fork, and post-prune save/restore all passed.

That host also exposed an important filesystem boundary. Its ZFS scratch
accepts `FICLONE`, but raw 8GiB sparse reflinks consistently took `151–155ms`;
the ReleaseFast gate measured `153.482ms` at 0% coverage and correctly failed
the `<100ms` assertion. The product path now places writable overlays and lazy
sparse bases under absolute `TMPDIR` rather than hard-coded ext4 `/tmp`, keeps
that factory root with every disk head, and rejects cross-filesystem adoption.
APFS remains the measured host for the slice's 8GiB `<100ms` and 32-head `<1s`
latency gates; the ZFS runner is Linux/KVM correctness coverage, not a Linux
8GiB latency reference. Requiring the same 8GiB gate on Linux would require a
faster reflink scratch filesystem or a different Linux clone primitive.

#### Key Learnings From Pressure-Testing

- The production seam is the source monitor's VMM quiescence path, not
  lifecycle: only that process owns the live map/fds and can prove the block
  queue is drained.
- An unlinked fd is a useful cleanup invariant. A linked runtime handoff would
  add TOCTOU and stale-file recovery problems, so children claim fds directly
  and the private descriptor remains non-portable. APFS may use a transient
  named clone only until it has opened and unlinked the resulting fd.
- Runtime overlay placement is part of fast-fork capability. Honoring absolute
  `TMPDIR` lets operators select a reflink-capable scratch filesystem; retaining
  that root with the live disk and checking fd filesystem identity prevents a
  child from becoming ready with a head it cannot natively fork again.
- The original in-process primitive was not a portable product boundary: it
  deep-copied digest strings and only attempted reflink on Linux. Stable
  baseline authority, transferable heads, and APFS cloning were prerequisites;
  the production path now supplies all three.
- Fast-disk timing must be measured separately from the existing RAM/machine
  capture and child startup. Calling `snapshotIndex()` would make the wiring
  functionally correct while missing the product goal.

### U7 — Partial materialization

Status: complete for local CAS fault-in and measured dense-image cold-flat
startup.

Add the `.cas` map source and fault-in path, then use a reference boot trace to
decide whether background fill or boot-critical chunk ordering is warranted.

Landed behavior: chunk-index disks and chunked rootfs caches can now open over
a sparse temporary base fd without assembling the full flat image first. The
chunk map marks nonzero index entries as `.cas`; the first read of a CAS chunk
opens the local object, verifies it against the descriptor-selected BLAKE3
digest, writes it into the sparse base, and promotes that map entry to `.base`.
Missing or corrupt objects fail the complete logical read before caller-visible
bytes change. Warm flat-cache opens still use the existing read-only
materialization path.
Managed `spore run --image` resolves chunked image-rootfs storage even without
`--save`, and cache lookup no longer repairs an evicted flat by-digest
materialization as a side effect, so a warm-CAS/cold-flat image run reaches the
lazy runtime path.

Before that lazy index is opened, `RuntimeDisk` validates and publishes the
existing baseline-lease JSON under the private runtime root while holding the
same rootfs cache lock as GC and destructive prune. Foreground runs and named
monitors therefore share one lifetime boundary. GC and prune retain the
descriptor-selected index and objects while the owner process is alive; normal
teardown removes the record after closing the runtime disk, and records left by
dead processes do not remain roots.

Decision: do not add a concurrent background filler or boot-critical priority
list. The dense-image fault trace below touched 34 of 19,035 nonzero chunks
before the first command completed. Fault service took about 6ms in total,
while eager materialization added about 2.7 seconds over lazy startup. A filler
would require synchronization around the hot chunk map and would reintroduce
eager whole-image work in another form. The guest's actual read stream is the
right ordering for this slice.

Validation: `mise exec -- zig test src/runtime_disk.zig` covers lazy rootfs
open without publishing a flat cache, wrong-sized flat-cache fallback, CAS
promotion after the first read, read-time missing-object failure, induced
eviction of an already promoted chunk, corrupt unread-object failure without
torn read data, and chunk-index disk restore over the lazy backend. The same
test graph also drives multi-chunk, multi-descriptor virtio-blk reads over a
lazy chunk-mapped disk for missing and same-size corrupt objects: both preflight
the complete logical range, complete the request with `status_ioerr`, advance
the used ring, copy no disk payload bytes into the guest, and then serve a
promoted healthy chunk on the same queue. Only the status byte is updated; the
non-overlapping test data segments remain sentinel-filled. Descriptor validation
also completes before I/O, so a malformed later segment cannot expose data
through an earlier valid segment or partially change backend bytes.
`src/system.zig` additionally opens a lazy runtime, runs destructive CAS prune
and mark/sweep GC, and proves the first read of an untouched object still
succeeds before checking that runtime teardown releases the lease.

Repeatable time-to-first-exec measurement lives in
`scripts/benchmark/suite.py` as the opt-in `lazy_rootfs_tti` benchmark. The
benchmark reports three rows per iteration:

- `lazy-cold`: evict flat materializations and boot through lazy CAS fault-in.
- `eager-cold`: restore, evict, then set the internal
  `SPOREVM_ROOTFS_EAGER_MATERIALIZE_FOR_BENCHMARK=1` escape hatch so
  `spore run --image` eagerly materializes the flat artifact from warm CAS
  before boot.
- `flat-hot`: reuse the hot flat materialization as the overhead baseline.

Lazy CAS tracing is also opt-in. When the benchmark supplies
`SPOREVM_ROOTFS_TRACE`, a lazy disk emits one bounded
`lazy_cas_fault_summary` JSONL record at teardown. Version 1 records runtime
open and index-attach time, exact owned index payload bytes, initial and
remaining CAS chunks, fault attempts/errors/bytes, and cumulative object
preparation, read, verification, and sparse-write time. Object preparation
includes path construction, path duplication, open and stat, and the read
buffer allocation. It is deliberately named for that whole boundary. The
record contains no paths or digests. `SPOREVM_ROOTFS_TRACE_SUMMARY_ONLY=1`
suppresses the older per-read events so tracing does not add a write syscall to
every fault. With tracing disabled, the fault path uses the original untimed
object reader and does not sample clocks.

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
assertions, but it is not asymptotic evidence. An earlier native 8 GiB cached
image was also rejected for that purpose: it contained only 70 non-zero CAS
chunks, so eager materialization did not scale with its nominal logical size.

The dense-image gate used the same pinned ARM64 Node base as the small check
plus a deterministic 1 GiB AES-CTR payload. BuildKit exported the rootfs as a
tar, then `spore rootfs import-tar` converted it into a complete local chunked
image. This is synthetic asymptotic evidence, not a representative production
image. The 1.85 GiB logical rootfs contained 19,035 nonzero 64 KiB CAS chunks,
comfortably above the 10,000-chunk admission threshold.

Three ReleaseSafe Linux/KVM iterations measured:

| Mode | Median TTI | Range |
| --- | ---: | ---: |
| `lazy-cold` | 214ms | 214–215ms |
| `eager-cold` | 2,918ms | 2,917–2,967ms |
| `flat-hot` | 164ms | 164–165ms |

Every lazy run faulted the same 34 unique chunks (2,228,224 bytes, 0.179% of
the nonzero chunk set) with zero errors, leaving 19,001 chunks in CAS. Mean
cumulative fault service was 6.04ms: 1.02ms object preparation, 1.67ms reading,
2.62ms verification, 0.64ms sparse writes, and 0.08ms other work. Runtime open
averaged 78.63ms; before runtime-index compaction, attaching the 3,704,220-byte
(3.53 MiB) owned index state averaged 2.28ms.

Follow-up decision: keep the canonical on-disk index unchanged, but store its
nonzero entries in the lazy runtime as one sorted `{ logical_chunk, ChunkId }`
array. CAS fault identity and logical parent identity are the same for every
unmodified `.cas` entry; promotion changes only the source tag, so a second
digest table was duplicate ownership. First faults use a bounded binary search,
while snapshots merge the sorted table with the chunk walk in O(N+K). Fork
copies the table once and grow leaves it unchanged. The exact dense-trace
dimensions now account for 791,898 owned bytes in four allocations, down from
3,704,220 bytes in 38,075 allocations (78.6% fewer bytes and 99.99% fewer
allocations). The regression test also covers one-entry and all-zero indexes,
so compaction does not trade dense savings for an ultra-sparse regression.

Those results close the remaining design gates. Do not add a background filler
or boot-priority list: demand faults already fetch a tiny, stable working set.
Do not add local packfiles: file-per-chunk open/read/verify service is only a few
milliseconds across the entire boot. Index compaction was not latency-urgent,
but the owned-allocation evidence above justified a narrow representation
change without touching the fault or format contracts. The original benchmark
did not sample process RSS; exact owned bytes and allocation count are the
repeatable proxy, not a claim about allocator or kernel accounting. Revisit any
of these decisions only when a representative workload produces materially
different traces. To repeat the timed portion against an admitted dense local
image, run:

```sh
python3 scripts/benchmark/suite.py --profile smoke --benchmarks lazy_rootfs_tti --iterations 3 --modes sequential --image <dense-local-image-ref> --output-dir zig-cache/sporevm-benchmarks/u7-lazy-rootfs-large --scratch-dir zig-cache/sporevm-benchmarks/u7-lazy-rootfs-large-scratch --timeout-s 900
```

Done: complete for the local lazy path, virtio-blk error completion, and
repeatable lazy/eager/flat TTI measurement. Cold-flat startup is bounded by the
boot working set, not full image assembly. Both the CI-sized check and the
dense synthetic run start the guest before full flat materialization; on the
dense run, eager materialization was about 13.6 times slower than lazy startup.
The measured fault path does not justify a background filler, boot-priority
ordering, or local packfiles. The runtime index now has compact, measured owned
storage without changing the on-disk index.

### U8 — Cleanup and docs

Status: landed for the unified-storage cleanup and production named-fork docs.

Remove transitional shims, update `docs/rootfs.md`/`docs/filesystem.md`
architecture sections, SECURITY.md parser inventory (net reduction: three
index parsers → one), release notes covering the format break and the new boot
behavior. Production named-fork documentation and release notes landed with U6.

Landed behavior: the unused public `CowDisk` backend and virtio-blk `.cow`
backend arm are gone; writable COW behavior now lives only inside
`ChunkMappedDisk`. Durable filesystem, rootfs, state-portability, security, and
release-note docs describe disk indexes, lazy CAS fault-in, the format break,
and the backend fork/runtime model. The lifecycle and security docs now cover
the exposed disk-backed `spore fork --vm` path as well.

Validation: `mise run test`, `mise run build`, and the conditional
`rootfs-slow-test` target. The slow graph validates chunk-index storage and
completeness for native/external imports. The remote rootfs bundle smoke emits a
current v2 synthetic manifest with a complete zero-memory index, and the writer
benchmark reports canonical index identity plus the current CAS preload phase.
Bundle pack consumes the descriptor-bound canonical index and verified objects
directly; it does not assemble or rescan the derived flat rootfs cache.

### Large-image save publication follow-up

Status: implemented. Machine-local saves now publish writable-disk objects,
their canonical index, and the derived completeness stamp in that order in the
global rootfs CAS, then durably pin the resulting root before final save
visibility. This lets repeated named saves hand the exact new baseline to a
restored VM without making nested fast fork depend on the original image's
completeness proof. The opaque pin and manifest binding live in
host-private lifecycle metadata, not the portable manifest. Restore is
local-first with validated pinned-CAS fallback; `spore pack` remains the
self-contained copy-and-verify boundary.

Pinned offline fork uses a hidden three-phase batch. RAM chunks, manifests, and
child references are prepared and synced before taking the rootfs-cache lock.
Under that lock the parent pin is revalidated, independently bound child records
are file-synced, the pin directory is synced once for the complete set, and only
then is the batch renamed into view and its destination parent synced. Failures
can leave reclaimable pin records, but never visible unpinned or partial
children. The result reports monotonic lock-wait and lock-held publication time
separately.

The native publication gate is complete. Physical same- and cross-filesystem
pack→unpack→run passed on distinct device IDs with the same verified bundle
digest (`bd13758c8df47d7b98725accaf56d390613abee6fdf0aec79c5c216c345ea0a5`),
17 chunks, and 35,651,584 payload bytes. Five samples at each fork scale minted
unique child pin references and completed public `spore rm --spore` cleanup:

| Children | Lock wait p50/p95 | Lock held p50/p95 | Lock held per child p50/p95 | Wall p50/p95 | Wall per child p50/p95 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0 / 0 ms | 28 / 28 ms | 28 / 28 ms | 106.995 / 107.990 ms | 106.995 / 107.990 ms |
| 32 | 0 / 0 ms | 32 / 33 ms | 1.000 / 1.031 ms | 212.737 / 214.686 ms | 6.648 / 6.709 ms |
| 1,000 | 0 / 0 ms | 153 / 155 ms | 0.153 / 0.155 ms | 3,505.735 / 3,537.499 ms | 3.506 / 3.537 ms |

This is O(N children), not O(N × disk objects). Unit coverage separately proves
one canonical-index validation per unique storage root and at most one
pin-registry parent-directory fsync for a batch.

Named continue-save logs the complete paused interval through durable final
publication. Its structured phases separate cache-lock wait, manifest/pin
authorization, active baseline-lease handoff, lifecycle-spec publication, and
the final rename plus parent-directory sync. This keeps the earlier backend
snapshot timings useful without hiding the durability work performed while all
vCPUs remain paused. The handoff acquires the exact new active lease, atomically
and durably replaces the continuing VM's source registry spec, swaps the
in-memory owner, and releases the old lease last. A failure before that commit
removes the candidate lease and preserves the old spec/root.

The product save path now emits a bounded schema-2 disk metric. It preserves
the schema-1 publication fields and adds disjoint clean-known-zero and
dirty-zero counts, so sparse capacity is distinguished from chunks that
required sealing/scanning and from nonzero parent reuse. The strict parser
retains schema-1 support for the historical evidence below. The metric
separates dirty and non-dirty chunks,
logical parent-reference bytes, unique parent bytes
published by hard link, existing-object reuse, or verified copy, and the
corresponding time plus the batched link-directory sync. It also records
dirty-object work, canonical index encoding and durable
publication, and total disk snapshot time. The existing backend snapshot metric
continues to report RAM and manifest publication separately.

The native evidence used ReleaseSafe revisions
`e83adad0d8f46c5f06261287d578e01fd78ffc58` for the initial same- and
cross-filesystem comparison, then
`ede5247dfc61d19e2735eae7cc2d6d022007e302` for the final-shape
same-filesystem rerun. Both ran on the standalone Linux/KVM `c7gd.metal` host.
The fixture repeated the U7 dense-image method using
`docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271`
plus a deterministic 1 GiB AES-256-CTR payload with an all-zero 256-bit key and
all-zero 128-bit IV, imported as a local chunked image. The resulting rootfs was 1,988,100,096 logical bytes,
30,336 chunks, and 19,023 unique nonzero parent objects. Each hot capture dirtied
only six chunks and reused 30,330 parent chunks, so the measurements isolate
publication of the existing global-CAS working set rather than a full scan.

Three product-path captures on each filesystem shape measured:

| Output relative to global CAS | Parent publication | Parent object operations | Disk snapshot | Product command |
| --- | ---: | ---: | ---: | ---: |
| same filesystem | 19,023 links / 1,246,691,328 bytes | 440 to 449 ms (445 ms median) | 483 to 493 ms (488 ms median) | 776 to 818 ms (781 ms median) |
| different filesystem | 19,023 copies / 1,246,691,328 bytes | 106.163 to 106.888 s (106.325 s median) | 106.243 to 106.968 s (106.408 s median) | 106.635 to 107.391 s (106.824 s median) |

The same-filesystem rows used a ZFS instance-store CAS and ZFS output. The
cross-filesystem rows kept the CAS on ZFS and wrote the spore to the host's
ext4 root volume. The sanitized per-iteration record is checked in at
`benchmarks/evidence/large-save-cost-2026-07-11.json`.

The final-shape same-filesystem run also measured the batched parent-directory
sync at 257 to 280 microseconds (259 microseconds median). KVM RAM capture took
25 to 26 ms, manifest publication took 0 to 1 ms, and the complete snapshot
took 509 to 519 ms. Those values keep the 445 ms parent-object work distinct
from RAM, manifest, and command-wall time.

The dense payload and import were built with:

```sh
image=docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271
docker pull --platform linux/arm64/v8 "$image"
cid=$(docker create --platform linux/arm64/v8 "$image")
docker export "$cid" -o rootfs.tar
docker rm "$cid"
dd if=/dev/zero bs=1M count=1024 status=none | \
  openssl enc -aes-256-ctr \
    -K 0000000000000000000000000000000000000000000000000000000000000000 \
    -iv 00000000000000000000000000000000 >dense.bin
tar --append --file rootfs.tar \
  --transform='s|^|opt/sporevm-save-cost/|' dense.bin
spore rootfs import-tar rootfs.tar --ref local/sporevm-save-cost:dense
```

The exact benchmark shape was:

```sh
scripts/benchmark/hot-run-save.sh \
  --spore-bin zig-out/bin/spore --backend kvm \
  --image <pinned-dense-local-ref> --memory 1024mb --iterations 3 \
  --cache-dir <global-cas-dir> --work-dir <same-filesystem-work-dir> \
  --output same.jsonl

scripts/benchmark/hot-run-save.sh \
  --spore-bin zig-out/bin/spore --backend kvm \
  --image <pinned-dense-local-ref> --memory 1024mb --iterations 3 \
  --cache-dir <global-cas-dir> --work-dir <different-filesystem-work-dir> \
  --output cross.jsonl
```

Decision: copying global-CAS chunks during save is a material cost, not a
hypothetical portability edge. Even the normal same-filesystem path spends
about 0.45 seconds issuing 19,023 hard links. A portable output on another
filesystem spends about 106 seconds verifying, copying, and durably publishing
the same 1.25 GB. The later shared-store save slice is warranted: local saves
should be able to reference rooted global-CAS objects and defer
complete/self-contained copying to an explicit export boundary. That follow-up
must preserve the existing cache-lock/GC-root contract and portable bundle
semantics. The landed durable-pin design removes unchanged-parent object
link/copy/hash operations from cache-backed steady-state saves whose parent is
already in the global CAS. A first save after portable/local-CAS restore still
performs a one-time verified migration into the global CAS; benchmark that
migration separately from steady-state save and same-/cross-filesystem export.
`spore rm --spore` removes the save before
unpinning under the cache lock. Raw moves preserve the opaque identity, while
raw copies share it and cannot be removed independently; fork or pack/unpack
creates an independent lifecycle boundary. Raw deletion safely leaks a pin.
`spore cache pins` reports IDs and index health without claiming orphan
detection, and expert-only `spore cache unpin ID --force` removes an exact known
ID. The pre-1.0 design deliberately has no global reference registry.

Mandatory immediate post-PR follow-up: move the durable offline-fork
transaction and portable shared-disk materialization out of `src/api.zig` into
a focused saved-spore fork module. The public API should retain only option
validation and result ownership; the new module should own the three-phase pin
transaction, current/V1 manifest normalization, fault injection, and durable
batch publication. This is sequencing work, not optional cleanup: the current
PR establishes the contract, and the next PR restores the API/module ownership
boundary before more saved-spore lifecycle behavior is added.

## Security

- Net parser reduction: the `DiskLayer` parser is deleted, and writable disks
  now use the hardened `DiskIndex` parser. Restore-authority surface shrinks.
- The chunk map is host-internal state derived from validated values. The
  virtio-blk wire/device model stays frozen; request validation now completes
  before I/O and lazy CAS sources prefault before payload copies.
- CAS objects remain verify-at-write, trust-at-open; index digests bind
  coverage and size exactly as `validateDiskIndex` does today.
- GC is a new destructive operation: it must be root-conservative (unknown
  record kinds are roots, not garbage) and tested against concurrent-ish
  root creation (lock protocol test).
- The snapshot freeze/drain must produce clean images, never
  crash-consistent guesses. In v1 this is satisfied structurally: snapshots
  run only at capture/save points where the VM is paused and virtio-blk
  writes are drained. The separate `spore build` work owns its online
  guest-`fsfreeze` checkpoint protocol; U6 captures complete VM state at one
  paused device epoch and does not publish a disk snapshot.
- Partial materialization (U7) puts CAS object reads on the guest I/O path
  for the first time: objects are digest-verified at fault-in before bytes
  reach the guest, and missing/corrupt objects surface as clean I/O errors
  to the guest, never hangs or silent zero-fill. U7 tests cover promoted
  chunk eviction and corrupt unread objects.
- Production fork handoff is host-private but still parser and fd authority.
  Its descriptor is strictly bounded and versioned, its single overlay fd is
  transferred with `SCM_RIGHTS` over a one-use child-bound claim, and bitmap
  data uses a separate exact-length binary frame rather than the 8KiB JSON line
  parser. All baseline lifetime, map shape, size, fd mode/type, framing, and
  ownership checks complete before adoption and before monitor readiness. The
  parser lands with a fuzz target; the existing monitor jail remains in force
  and the guest-visible device model does not change.

## Resolved Decisions

- This plan is the storage/runtime architecture for fast boot and fast fork,
  not a standalone simplification: fork and partial materialization are
  in-plan milestones (U6, U7), not extensions.
- Memory/disk parity is in-plan, not aspirational: RAM is the reference
  implementation of the model, disk adopts its identity plus the shared
  classification, publication, and work-accounting primitives (U3), and memory
  adopts the unified index encoding (U5).
  Chunk granularity stays per-domain (RAM 2MiB, disk 64KiB). Evidence now
  justifies a separate store-unification save follow-up; its design remains
  open.
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
  references is durable in a store. `spore build` therefore publishes each
  per-instruction child index only after its O(dirty) chunk publication has
  completed; cache records never point at half-durable state.
- Fork and durable-child are two named operations, not one configurable
  mechanism: `fork` = map copy + overlay reflink, ephemeral, no identity;
  durable children come from `snapshot()` + open. A live fork head crosses
  process boundaries only as a one-use private descriptor plus unlinked fd,
  backed by an independently rooted baseline lease, never as a new manifest
  kind or persistent linked overlay path. Reflink is a host-fs capability;
  fast fork fails closed without it unless the caller explicitly opts into
  the measured dirty-chunk copy path.

## Open Questions

- Chunk object packing (many small files vs packfiles) is closed for the current
  runtime. File-per-chunk has shipped through the unified storage slices: RAM
  already runs file-per-chunk at 2MiB without trouble, and incremental
  snapshots mostly skip writes via write-if-missing. The dense U7 trace faulted
  only 34 objects, with object preparation, read, and verification totaling
  about 5.3ms. That does not justify trading away the simple write-if-missing
  dedupe and unlink-based GC. Reopen this only if representative fault traces
  show materially larger working sets or object-service cost; the index format
  is unaffected either way.
