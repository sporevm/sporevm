---
status: active
last_reviewed: 2026-06-20
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/distribution.md
  - docs/plans/immutable-rootfs-resume.md
  - docs/plans/writable-disk-layers.md
  - docs/spore-format.md
  - docs/rootfs.md
  - SECURITY.md
related_plans:
  - docs/plans/foundation.md
  - docs/plans/distribution.md
  - docs/plans/immutable-rootfs-resume.md
  - docs/plans/writable-disk-layers.md
---

# Chunked Rootfs Block Source Plan

## Summary

Warm completed-base-spore fan-out is now bottlenecked by immutable rootfs
handling, not by fork metadata or writable disk-layer mechanics. Forking
children is cheap, and writable rootfs changes can be sealed and distributed as
content-addressed disk layers. But product `spore run --from` still opens a
monolithic ext4 artifact from the rootfs digest cache and verifies the whole
logical artifact before VM creation.

The next storage slice should make the immutable rootfs base a verified block
source. The guest contract stays unchanged: Linux still sees a normal
`virtio-blk` root disk. Internally, clean reads come from a `BlockSource`
interface. The first implementation is fd-backed and behavior-preserving; the
follow-up `CasBlockSource` uses a small verified rootfs index plus verified
content-addressed chunks.

This deliberately avoids making a local rootfs proof sidecar the primary
architecture. A sidecar may be a useful compatibility optimization for the
fd-backed path, but it preserves the monolithic artifact model and adds another
local provenance mechanism. The product architecture should converge on one
content-source story for RAM chunks, immutable rootfs chunks, and writable disk
objects.

## Problem

The current immutable rootfs contract is correct but too expensive for warm
same-host fan-out:

- capture records rootfs digest, size, device binding, and provenance;
- resume resolves the digest-cache ext4 path;
- resume re-hashes the full artifact before attaching the fd;
- `spore run --from` only runs the guest command after that rootfs work, RAM
  restore, and vsock readiness.

Recent product-path timing showed roughly 5-6 seconds per child in rootfs open
and digest verification on a 512MiB logical artifact. PR #115 attacks the local
RAM restore cost. Writable disk layers attack mutable rootfs state. The
remaining rootfs cost needs a different base architecture: verified sparse block
reads rather than full-file preflight verification.

## Goals

- Preserve the guest-visible root disk as ordinary `virtio-blk`.
- Refactor clean block reads behind a small `BlockSource` boundary.
- Keep existing fd-backed rootfs behavior working through `FileBlockSource`.
- Prove a `CasBlockSource` can avoid full-rootfs verification before
  `spore run --from` child execution.
- Choose immutable-rootfs chunk size from measured fan-out/read economics, not
  from the writable-layer 4KiB default.
- Align distribution so RAM chunks, rootfs chunks, and writable disk objects can
  share content-source and cache machinery while keeping separate indexes and
  semantics.

## Non-Goals

- Changing the guest-visible root disk ABI.
- Replacing writable disk layers or making rootfs chunks writable.
- General block-device support beyond the rootfs-bound disk chain.
- Remote lazy reads on the first slice.
- Filesystem-semantic restore authority, FUSE, NFS, 9p, or virtio-fs.
- A public compatibility promise before 1.0.

## Target Model

The root disk read path becomes:

```text
virtio-blk
  -> CowDisk / LayeredCowDisk
       dirty cluster -> local active head
       sealed cluster -> disk-layer object store
       clean cluster -> BlockSource

BlockSource
  FileBlockSource: current rootfs fd
  CasBlockSource: rootfs chunk index + local CAS objects
```

`FileBlockSource` is the behavior-preserving adapter. It reads from the current
verified ext4 fd and lets the rest of the runtime stop assuming that a clean
rootfs read is always a `pread` on a stored `base_fd`.

`BlockSource` is only an I/O boundary. It is not a trust boundary and must not
create a new path for attaching unverified rootfs bytes. `FileBlockSource` may
only wrap an fd that came from the existing verified rootfs cache path, or an
equivalent verify-the-same-fd-before-attach path.

`CasBlockSource` is the product follow-up. A manifest-selected rootfs storage
descriptor is the restore authority for the chunked base. It must not reuse the
existing `rootfs.source` field, which is OCI provenance only. The exact manifest
field name can land in Slice 3, but the descriptor must live under rootfs storage
or artifact identity, not provenance:

```text
rootfs_storage:
  kind: chunked-ext4-rootfs-v0
  device: virtio-mmio rootfs slot
  logical_size: <bytes>
  chunk_size: 4096 | 16384 | 65536 | 262144 | ...
  hash_algorithm: blake3
  index_digest: blake3:<canonical-rootfs-index-bytes>
  base_identity: blake3:<canonical-rootfs-index-bytes>
  object_namespace: rootfs/blake3
```

The rootfs index records the layout selected by that descriptor:

```text
rootfs-block-index-v0
  kind: chunked-ext4-rootfs-v0
  logical_size: <bytes>
  chunk_size: 4096 | 16384 | 65536 | 262144 | ...
  hash_algorithm: blake3
  object_namespace: rootfs/blake3
  base_identity: blake3:<canonical-rootfs-index-bytes>
  chunks:
    logical_chunk -> blake3:<chunk-bytes>
  zero_chunks:
    logical_chunk
```

The exact table shape can change after the experiment, but the descriptor
binding cannot. Resume first verifies that the canonical index bytes match the
manifest's `index_digest`, then verifies only chunks it inserts into the cache or
serves to the guest. A clean same-host fan-out path should not re-hash the full
rootfs artifact for every child before VM creation, and it should not allow a
cache or bundle to redefine logical size, chunk size, algorithm, zero-fill
semantics, object namespace, device binding, or base identity. Writable disk
chains must bind `disk.base` to this same rootfs base identity when the immutable
base is chunked; for the fd-backed path, the base identity remains the current
full ext4 artifact digest. For the first chunked storage kind, `base_identity`
is exactly `index_digest`; do not introduce an independently supplied digest that
can drift from the canonical index bytes.

## Safety Invariants

- The selected manifest remains restore authority. OCI refs, paths, and remote
  URLs are provenance or byte sources only.
- The existing `rootfs.source` field remains provenance only. Chunked rootfs
  authority must use a separate storage/artifact descriptor so OCI metadata never
  becomes restore authority by field-name accident.
- Writable disk `base` validation must compare against the effective rootfs base
  identity. For fd-backed rootfs this is the full ext4 artifact digest; for
  chunked rootfs this is the manifest-bound chunked base identity.
- `BlockSource` is not a verification bypass. New block sources must make their
  root of trust explicit and fail closed before the VM can observe bytes outside
  that trust contract.
- Every rootfs chunk is verified against its BLAKE3 identity before guest use.
- A missing, corrupt, or unsupported rootfs index fails before attaching the
  block backend.
- `FileBlockSource` keeps the existing full-rootfs verification behavior and can
  only be constructed from an already verified rootfs fd until a manifest
  explicitly selects chunked rootfs storage.
- `CasBlockSource` can only attach when the manifest-selected descriptor matches
  the verified canonical index bytes and the index fields exactly match the
  descriptor.
- `CasBlockSource` must not trust local paths, cache hits, or bundle indexes
  without verifying chunk identities.
- Rootfs index and chunk cache installation is atomic and symlink-safe: write to
  temporary regular files, verify identity and size, set final permissions, then
  publish by atomic rename. Readers must never serve partially written cache
  entries.
- Writable disk objects remain separate restore-authority objects. Rootfs
  chunks are immutable base data, not sealed mutations.
- Rootfs chunk indexes and writable disk layer indexes stay distinct even if the
  object cache and transfer machinery are shared.

## Current State

- Slice 1 is implemented in `src/block_source.zig`, `src/cow_disk.zig`, and
  `src/disk_layer.zig`. `BlockSource` currently has a `FileBlockSource`
  implementation, and `CowDisk` / `LayeredCowDisk` clean reads now go through
  that boundary instead of storing a base fd directly.
- Direct read-only `.file` attachments in `virtio-blk` remain unchanged. Product
  rootfs-backed writable disks still open and verify the rootfs fd before
  constructing the fd-backed `FileBlockSource`.
- Validation for Slice 1: `mise run test`, `mise run build`, and
  `mise run smoke:writable-rootfs` passed on 2026-06-20. The test suite includes
  a corrupt digest-cache rootfs regression proving `openRuntimeDisk` fails before
  constructing the `FileBlockSource`-backed COW path.
- Slice 2 has a first product-path result from a 512MiB
  `docker.io/library/node:22-alpine` rootfs on local HVF. A hot completed-base
  child where the base had already run `node -v` took 3.8s to re-verify the full
  rootfs and performed zero clean rootfs reads before returning `node -v`. A
  colder child where the base captured `/bin/true` then ran `node -v` took 3.8s
  to verify the full rootfs and read 28.6MiB from the clean rootfs base. Projected
  chunk verification for that cold trace was 28.6MiB at 4KiB, 29.5MiB at 16KiB,
  32.0MiB at 64KiB, and 37.2MiB at 256KiB.
- After adversarial review, Slice 2 grew a local replay control rather than
  moving straight to manifest format work. The replay materializes local
  content-addressed chunk objects and replays the traced reads with cached and
  uncached verification. On the cold Node trace, cached 64KiB replay hashed
  31.9MiB through 487 object opens in 26.9ms, while the deliberately bad
  uncached 64KiB replay hashed 458MiB through 6,990 object opens in 307.0ms. A
  proof-sidecar control that only stats the rootfs and parses a tiny proof took
  74us, which proves the same-host baseline is credible but not a complete
  restore-authority design. The replay uses SHA256 as a mechanics proxy; runtime
  rootfs chunks still need BLAKE3 identities.

## Delivery Strategy

### Slice 1: BlockSource Boundary

Add a small block-read abstraction and move the current fd clean-read behavior
behind `FileBlockSource`.

Scope:

- introduce `BlockSource` with `capacityBytes` and `readAt`;
- refactor `CowDisk` and `LayeredCowDisk` clean reads from `base_fd` to a
  `BlockSource`;
- keep the raw `.file` virtio-blk backend for direct read-only attachments;
- preserve current manifest and rootfs cache behavior.

Done when `mise run build`, `mise run test`, and `mise run smoke:writable-rootfs`
pass with no product behavior change. The slice must also include a negative
test or smoke that corrupts a digest-cache rootfs artifact and proves resume
still fails before VM creation through the `FileBlockSource` path.

### Slice 2: Rootfs Chunking Kill-Or-Commit Experiment

Build a product-path experiment over real cached ext4 rootfs artifacts and
representative `spore run --from` commands. The goal is to decide whether
chunked rootfs should proceed at all before investing in the descriptor, parser,
and `CasBlockSource`.

Measure:

- full-file rootfs verification time in the current fd-backed path;
- clean rootfs read offsets and lengths for warm child commands;
- projected chunk verification bytes for 4KiB, 16KiB, 64KiB, and 256KiB;
- index bytes per rootfs;
- chunk count and object count;
- warm-cache child startup impact.
- cached and uncached replay cost for traced reads;
- proof-sidecar control cost for same-host fan-out.

Defer broader image-registry data until before choosing defaults:

- unique chunk bytes across related OCI images;
- package-manager-heavy rootfs variants;
- cross-image object count and dedupe sensitivity for 16KiB, 64KiB, and 256KiB.

Done when the plan records a clear proceed, stop, or proof-sidecar-first
decision. The first local Node result is a proceed-to-prototype signal, not a
format/default lock: full-file verification cost was roughly equal to child TTI,
while the cold child trace would verify only 5.3-6.9% of the rootfs depending on
chunk size. The replay control makes one requirement explicit: the runtime
`CasBlockSource` must memoize verified chunks for the lifetime of the VM or it
can re-hash hundreds of MiB through repeated small guest reads. Use 64KiB as the
first balanced `CasBlockSource` prototype chunk size because it keeps overfetch
modest at 12%, cuts touched chunks from 6,990 to 488 for the cold trace, and
keeps a binary whole-image index around 85KiB. Keep 256KiB in the benchmark
because it was locally faster in replay, and keep the proof-sidecar control in
the benchmark because it is the simplest same-host baseline.

### Slice 3: Cached CasBlockSource Runtime Spike

Build a local runtime spike before locking the manifest/index format. It should
use a generated index and local object store derived from one digest-cache rootfs
artifact, then attach through a cached `CasBlockSource` under an experimental
path.

Scope:

- no manifest schema change;
- no remote reads;
- no S3 path;
- no distribution bundle changes;
- no fallback to rebuilding missing chunks during resume;
- verify every object against its content identity before first use;
- memoize verified chunks per VM so repeated guest reads are cache hits;
- emit stats for chunk accesses, cache hits, misses, object opens, bytes hashed,
  and zero fills;
- compare same-host child TTI against the current fd-backed full verification
  path and a proof-sidecar control.

Done when a warm `spore run --from <child> -- node -v` or equivalent
rootfs-backed command shows whether cached chunk verification improves real
child TTI, and the report includes p50/p95 for 10-child and 100-child fan-out.
If the spike is not clearly faster than the proof-sidecar control for same-host
fan-out, keep the proof sidecar as the local optimization path and continue
chunked rootfs only for distribution economics.

### Slice 4: Rootfs Storage Descriptor And Index Parser

Add the manifest-bound chunked rootfs descriptor and canonical rootfs index
parser without attaching it to product resume yet.

Scope:

- define `chunked-ext4-rootfs-v0` as an experimental manifest storage kind;
- require descriptor fields for logical size, chunk size, hash algorithm, index
  digest, rootfs base identity, object namespace, and device binding;
- require `base_identity == index_digest` for `chunked-ext4-rootfs-v0`;
- keep OCI provenance in the existing `rootfs.source` field and add the chunked
  descriptor under a separate rootfs storage/artifact field;
- update writable disk base validation to use the effective rootfs base identity
  instead of assuming the base is always the monolithic ext4 artifact digest;
- parse canonical index bytes and reject unknown versions, duplicate chunks,
  out-of-range chunks, chunk-size mismatches, logical-size mismatches, digest
  algorithm mismatches, base-identity mismatches, path traversal, unsupported
  zero-fill encoding, and non-canonical ordering;
- add the parser fuzz target and update `docs/spore-format.md` and `SECURITY.md`
  in the same slice.

Done when malformed or mismatched descriptors and indexes fail before any block
backend can be constructed. This slice should use the runtime spike results to
choose only the fields needed for the first product path.

### Slice 5: Manifest-Attached Local CasBlockSource Prototype

Import or derive a chunked rootfs index and local object store for one cached
rootfs artifact. Attach it through the manifest-selected descriptor and
`CasBlockSource` for `spore run --from` on completed-base spores.

Keep the first prototype local-only:

- no S3 path;
- no remote lazy reads;
- no fallback to rebuilding missing objects during resume;
- fail closed on missing or corrupt chunks.
- memoize verified chunks per VM so repeated guest reads do not re-open and
  re-hash the same object.

Done when warm `spore run --from <child> -- node -v` or an equivalent
rootfs-backed command avoids the current full-rootfs verification phase without
moving the same cost into synchronous boot reads. Report:

- rootfs open/index verification time;
- chunks read and verified before first command execution;
- chunk cache hits and misses before first command execution;
- object opens and bytes hashed before first command execution;
- rootfs bytes verified before first command execution;
- total rootfs verification CPU time;
- command time after the exec bridge is ready;
- child TTI p50/p95 for 10-child and 100-child same-host fan-out;
- cold first-child overhead against the current monolithic path.

### Slice 6: Distribution Convergence

Extend bundle and pull materialization so chunked rootfs objects use the same
verified content-source machinery as RAM chunks and writable disk objects.

Done when a digest-pinned pull can materialize a selected child with chunked
rootfs base data, sealed writable disk layers, and RAM chunks from one verified
bundle/cache story. This slice also updates `docs/plans/distribution.md` so the
distribution contract distinguishes exact-byte rootfs artifacts from chunked
rootfs storage descriptors and keeps both manifest-authoritative.

## Verification

- Unit tests for `BlockSource` range checks, partial reads, EOF/short read
  handling, and COW read precedence through `FileBlockSource`.
- Negative test proving `FileBlockSource` does not weaken the current
  full-rootfs verification invariant on corrupt digest-cache artifacts.
- Unit tests for rootfs index parsing, canonical ordering, duplicate chunk
  rejection, range overflow, missing chunks, descriptor mismatch, zero-fill
  semantics, and digest mismatch.
- Fuzz target for the rootfs chunk index parser in the same slice that
  introduces the parser.
- Atomic cache install tests for rootfs indexes and chunks, including interrupted
  writes and concurrent cache hits.
- Product smoke proving writable rootfs layers still work after the
  `BlockSource` refactor.
- Benchmark with phase timing and 10/100-child TTI p50/p95 for warm
  `spore run --from` children before and after `CasBlockSource`.
- Negative smoke: corrupt one rootfs chunk and prove resume fails before guest
  use.

## Resolved Decisions

- Do not make a rootfs proof sidecar the primary architecture. It remains a
  credible same-host `FileBlockSource` optimization and a required benchmark
  control, but it does not solve cross-host chunk distribution by itself.
- Do not reuse the writable disk layer's 4KiB cluster result as the immutable
  rootfs default without measuring rootfs read/fan-out economics.
- Keep rootfs chunks, RAM chunks, and writable disk objects semantically
  distinct even if they share object storage and transfer code.
- The manifest-bound chunked rootfs storage descriptor is the authority for
  layout and identity. The local cache, bundle index, or transfer source may
  provide bytes, but cannot redefine logical size, chunk size, hash algorithm,
  object namespace, zero-fill semantics, or device binding.
- For `chunked-ext4-rootfs-v0`, the rootfs base identity used by writable disk
  layers is the canonical index digest. A later Merkle tree can change lookup
  internals, but changing the base identity rule requires a new storage kind.
- Do not overload the current `rootfs.source` OCI provenance field. Chunked
  rootfs storage authority needs a distinct field and an effective base identity
  that writable disk layers can validate against.
- Proceed to a local cached `CasBlockSource` prototype before locking the
  descriptor/parser shape. The first product-path experiment showed that
  same-host child TTI can be dominated by full-rootfs verification even when the
  child performs zero clean rootfs reads, and the colder Node child only needed a
  sparse rootfs working set. The replay control showed cached chunk verification
  is materially different from the no-cache failure mode.
- Use 64KiB as the first balanced local `CasBlockSource` prototype chunk size,
  not as a final default. Keep 16KiB and 256KiB in benchmark output while the
  image-registry experiment broadens; 256KiB was fastest in the local replay, but
  it overfetches more rootfs data and may weaken cross-image dedupe.

## Open Questions

- Should the first rootfs index be a flat chunk table, a Merkle tree, or a small
  table plus a tree root? The descriptor still binds the canonical index bytes
  by `index_digest`; this question affects lookup and verification cost, not
  restore authority.
- Should rootfs chunks use the same on-disk object directory as RAM chunks, or a
  namespaced rootfs object directory with shared cache plumbing?
- Does broader image-registry data contradict the first 64KiB prototype default,
  especially for cross-image dedupe and package-manager-heavy rootfs variants?
- Should `spore rootfs build` emit chunked rootfs objects directly, or should a
  separate preload/import command convert existing digest-cache ext4 artifacts?
- Should a local proof sidecar ship as a same-host fd-backed optimization before
  chunked rootfs distribution, or stay only as a benchmark control?

## Key Learnings From Pressure-Testing

- A local proof sidecar is pragmatic but preserves the monolithic artifact
  model and adds another local provenance path. It should not be the primary
  fast-fanout architecture.
- The first PR must be only the `BlockSource` boundary. Jumping straight to CAS
  rootfs would mix abstraction risk with index, cache, and performance risk.
- Chunked immutable rootfs and writable disk layers are adjacent but separate
  concerns: immutable base reads optimize fan-out startup, while sealed mutable
  layers preserve exact guest disk mutations.
- The dangerous failure mode is not a bad chunk-size choice; it is a new path
  that attaches unverified or incorrectly described rootfs bytes. The plan now
  requires the descriptor/parser/security slice before `CasBlockSource` is used
  by manifest-attached product resume.
- Avoiding the full-file hash is not enough to call the work fast. The benchmark
  must prove child TTI improves and that verification work is not merely shifted
  onto synchronous guest block reads.
- Verified chunk caching is a hard runtime requirement. The replay control showed
  that without caching, 64KiB chunks on the cold Node trace would re-hash 458MiB
  through 6,990 object opens, which is close enough to the monolithic tax to
  erase much of the win.
