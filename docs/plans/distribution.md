---
status: active
last_reviewed: 2026-06-21
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/immutable-rootfs-resume.md
  - docs/spore-format.md
  - SECURITY.md
  - src/bundle.zig
  - src/rootfs.zig
  - src/resume.zig
  - src/spore.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/immutable-rootfs-resume.md
---

# Pull-Based Distribution Plan

## Summary

Distribution turns a captured spore and its forks into artifacts that schedulers
can place on a fleet. The product shape should be pull-based: producers publish
a verified bundle once, workers pull the child they need by digest, and
`spore resume` boots only after the local bytes have been verified.

SporeVM owns the artifact format, verification, node-local cache, and local
materialization path. Placement stays outside this repository so Buildkite,
Cleanroom, Kubernetes, or another scheduler can decide which host should run
each child.

The first implementation should keep the runtime failure boundary simple:
`spore pull` fully materializes one selected child before `spore resume` starts.
The underlying design should not assume complete materialization is the only
future policy. Bundle indexes, content caches, and resume wiring should be
lazy-capable so later work can fetch verified chunks on demand without changing
the manifest contract.

Rootfs-backed bundles are self-contained by default. If a selected manifest
requires an immutable fd-backed rootfs artifact, `spore pack` includes the exact
ext4 bytes named by the rootfs digest. If the manifest selects chunked rootfs
storage, `spore pack` includes the descriptor-bound rootfs block index and the
BLAKE3 chunk objects it names. Metadata-only rootfs behavior remains an explicit
prepared-cache opt-out for indexed exact-rootfs bundles, and materialized
unpack/pull require both an allow flag and a verified destination cache hit.

## Problem

The foundation smokes prove the low-level mechanics: chunkpack bundles, remote
restore, host-local cache reuse, source-peer seeding, corrupt-bundle rejection,
and larger star/tree fan-out harnesses. They are still smoke topologies rather
than a product surface.

The missing product contract is:

- how a parent and many child manifests are bundled without duplicating shared
  chunks;
- how immutable rootfs bytes travel with, or alongside, memory chunks while
  keeping their trust models distinct;
- how a worker asks for one child by digest and materializes a normal spore
  directory locally;
- how a remote store is used without making SporeVM responsible for fleet
  placement;
- how the first complete-pull implementation avoids closing off later lazy-pull
  and preheat policies.

Central push fan-out is the wrong default because it couples SporeVM to
placement. Pull-based materialization lets a scheduler place work and lets each
worker fetch exactly the verified artifact it is about to resume.

Metadata-only rootfs distribution is also the wrong default. It creates bundles
that look portable but fail on a clean destination because the manifest names a
rootfs digest without carrying the bytes needed to satisfy it.

## Goals

- Define a pull-based artifact contract for parent spores, child spores, memory
  chunkpacks, and immutable rootfs artifacts.
- Keep manifest BLAKE3 chunk references and rootfs BLAKE3 digests as restore
  authority.
- Make rootfs-backed bundles resumable on a clean compatible host by default.
- Let workers materialize one child without downloading or copying shared bytes
  per child.
- Keep the content-source boundary lazy-capable even though the first
  implementation fully materializes a selected child.
- Reuse node-local caches across repeated pulls on the same host.
- Support a first remote store path that is boring, scriptable, and easy to
  measure before adding peer-to-peer machinery.
- Keep CLI verbs clear: `pack`/`unpack` are local artifact operations,
  `push`/`pull` move artifacts to and from stores, `resume` runs a materialized
  spore, and `fanout` remains local/demo orchestration.

## Non-Goals

- Kubernetes controllers, CRDs, scheduler plugins, or placement policy.
- A peer-to-peer daemon, gossip protocol, DHT, or torrent-style scheduler in the
  first implementation slices.
- Lazy remote reads during `spore resume`, cache-only preheat mode, or partially
  materialized spores as first shipped product behavior.
- OCI image policy, network policy, secrets, workspace semantics, or Cleanroom
  integration policy.
- General block-device distribution. The rootfs-bound writable disk chain is a
  manifest-backed artifact and is in scope for bundle materialization.
- Public compatibility promises before 1.0.

## Target Model

The intended product flow is:

```console
spore run --image docker.io/library/ruby:3.3-alpine \
  --capture ruby.spore \
  --capture-on USR1 \
  -- ruby /demo/counter.rb

spore fork ruby.spore --count 100 --out ruby.children/
spore pack ruby.spore --children ruby.children/ --out ruby.bundle/
spore push ruby.bundle/ s3://sporevm-artifacts/runs/ruby.bundle/

spore pull s3://sporevm-artifacts/runs/ruby.bundle@sha256:<bundle> \
  --child 42 \
  --out ruby-42.spore
spore resume ruby-42.spore
```

The exact flags can change as implementation lands, but the contract should not:
a worker pulls by immutable bundle identity, selects one child, verifies all
referenced memory and rootfs bytes, writes a normal spore directory, then resumes
it through the existing product path. This is the first materialization policy,
not the only architecture the artifact model should allow.

The distribution bundle extends the current local bundle shape rather than
replacing the spore manifest contract:

```text
<bundle>/
|-- bundle.json                     # bundle metadata, child table, digests
|-- manifests/
|   |-- parent.json                 # portable parent manifest
|   `-- children/000042.json        # portable child manifest
|-- chunkpack.index.json            # blake3 chunk id -> pack/offset/length/sha256
|-- chunkpacks/000000.pack          # uncompressed logical chunks concatenated
|-- rootfs.index.json               # optional rootfs digest -> artifact metadata
|-- rootfs/blake3/<hex>.ext4        # optional exact immutable rootfs bytes
|-- rootfs/blake3/indexes/<hex>.json # optional chunked rootfs block indexes
|-- rootfs/blake3/objects/<hex>.chunk # optional chunked rootfs objects
|-- disklayers/blake3/<hex>.json    # optional writable disk layer indexes
`-- diskobjects/blake3/<hex>.cluster # optional writable disk cluster objects
```

`manifest.json` and its BLAKE3 memory chunk ids remain the restore-time trust
root. The bundle index and SHA256 segment hashes are transport and cache
metadata. Rootfs artifacts stay separate from memory chunks: their manifest
section records `kind`, read-only mode, device binding, BLAKE3 digest, size, and
provenance, and `spore resume` must still verify the exact fd it will attach.
Writable disk layer indexes and disk objects are also bundle payloads when a
selected manifest records a `cow-block-v0` root disk chain. They stay separate
from memory chunkpacks and rootfs artifacts; the manifest layer refs and object
digests remain restore authority.

Rootfs inclusion is the default artifact policy:

- If any selected manifest records an immutable fd-backed rootfs artifact,
  `spore pack` verifies the source digest-cache ext4 by BLAKE3 and size, then
  includes it in the bundle once per rootfs digest.
- If the required rootfs bytes are absent or mismatched on the packing host,
  `spore pack` fails rather than emitting a misleading portable bundle.
- If any selected manifest records `rootfs.storage` with
  `chunked-ext4-rootfs-v0`, `spore pack` reads the exact
  `rootfs-block-index-v0` named by `rootfs.storage.index_digest`, verifies it
  against the manifest descriptor, copies it to
  `rootfs/blake3/indexes/<hex>.json`, and copies each referenced nonzero chunk
  object to `rootfs/blake3/objects/<hex>.chunk` once by digest.
- The default rootfs artifact policy is exact bytes. `spore pack --children ...
  --rootfs=metadata-only` is an explicit opt-out for indexed bundles whose
  destinations already have the verified rootfs cache entry.
- `spore unpack` and `spore pull` install bundled rootfs artifacts into the
  node-local digest cache by default, verifying digest and size before writing a
  resumable spore.
- `spore unpack` and `spore pull` install bundled chunked rootfs storage into
  the node-local rootfs CAS cache by default, verifying the index digest,
  descriptor fields, chunk sizes, and each chunk BLAKE3 digest before writing a
  resumable spore.
- A metadata-only bundle may be unpacked or pulled only with
  `--allow-metadata-only-rootfs`, and only when the selected rootfs cache already
  has the required verified bytes.
- If any selected manifest records writable root disk layers, `spore pack`
  copies the referenced disk layer indexes and BLAKE3 disk objects into the
  bundle once by digest. `spore unpack` and `spore pull` verify those bytes
  before writing a resumable spore.

The internal boundary should be:

```text
child manifest -> verified content source -> local materialization/resume input
```

The first content source can read from unpacked bundles, ordinary spore
directories, and the node-local cache. Later content sources can use object-store
range reads, peer fetch, or preheated cache entries. Those later sources must
preserve the same rule: every byte is verified before it becomes guest memory or
an attached rootfs fd.

## Safety Invariants

- A mutable tag, local path, or remote URL is never restore authority.
- Every memory chunk is verified against its BLAKE3 id before use, regardless of
  whether it came from origin, a local cache, or a later peer.
- Bundle digests key caches and remote references, but do not replace per-chunk
  or per-rootfs verification.
- Bundle digests cover every file that affects materialization, including
  `manifest.json`, bundle indexes, chunkpack blobs, rootfs indexes, included
  rootfs ext4 artifacts, disk layer indexes, and disk objects, in a canonical
  order.
- Bundle chunkpacks remain seekable by chunk id, offset, and length. Avoid a
  distribution format that requires downloading or decompressing the whole bundle
  before one referenced chunk can be verified.
- Rootfs artifacts are exact bytes, opened read-only, checked by BLAKE3 and
  size, included by default for portable bundles, and kept distinct from memory
  chunkpacks.
- Disk layer indexes and disk objects are BLAKE3-addressed, included by default
  when selected manifests reference them, and kept distinct from memory
  chunkpacks and rootfs artifacts.
- Rootfs cache installation is atomic and symlink-safe: write a temporary
  regular file outside the final digest path, verify size and BLAKE3, set the
  final permissions, then rename into the digest-addressed cache path.
- `spore pull` refuses path traversal, unknown bundle schema versions, missing
  child manifests, digest mismatches, and incompatible platform contracts before
  writing a resumable spore.
- Corrupt origin, cache, or peer data fails closed in the same way.

## Current State

- `spore pack` and `spore unpack` round-trip one portable memory/rootfs bundle
  with `manifest.json`, `chunkpack.index.json`, chunkpacks, optional
  `rootfs/blake3/<hex>.ext4` artifacts, optional writable disk layer/object
  files, `bundle_digest`, chunk verification, rootfs digest-cache installation,
  and disk layer/object verification.
- `spore pack --children DIR` writes an indexed local bundle with
  `bundle.json`, `manifests/parent.json`, `manifests/children/<id>.json`,
  shared chunkpacks, and optional `rootfs.index.json` entries with explicit
  rootfs artifact policy.
- `spore unpack --child ID` can materialize one selected child from an indexed
  local bundle into a normal spore directory.
- `spore pull file://... --child ID` materializes one selected child from an
  indexed local bundle through a verified local bundle content source, reusing a
  node-local BLAKE3 chunk cache where hard links are available.
- `spore push BUNDLE s3://BUCKET/PREFIX/` publishes indexed bundles to S3 by
  uploading the canonical bundle file set named by validated metadata, including
  referenced disk layer/object files.
- `spore pull s3://BUCKET/PREFIX@sha256:<bundle> --child ID --out DIR`
  downloads only that canonical file set, verifies the bundle digest, reports
  `remote.origin_bytes_read`, `remote.cache_hit`,
  `materialization.cache.bytes_fetched`, `materialization.cache.bytes_reused`,
  and rootfs cache hit/fetch/reuse metrics, then materializes through the same
  verified local content source as `file://` pull, including disk layer/object
  checks.
- `spore pull http://PEER:PORT/spore.bundle@sha256:<bundle> --child ID --out DIR`
  treats a peer as a static byte source, downloads only the canonical bundle
  file set, verifies the bundle digest before materialization, reports
  `remote.peer_bytes_read`, and reuses the node-local remote bundle cache on
  repeated pulls.
- Remote smoke metrics report `unique_content_bytes`, `origin_egress_bytes`,
  `origin_egress_multiplier_vs_bundle`, and
  `origin_egress_multiplier_vs_unique_content`. In source-peer mode the source
  peer is the measured origin edge; otherwise object-store origin bytes are.
  Passing `--max-origin-egress-multiplier-vs-bundle` or
  `--max-origin-egress-multiplier-vs-content` to
  `scripts/smoke-remote-bundle.sh` turns those measurements into a release gate.
- Indexed bundles now carry manifest-attached chunked rootfs storage. A selected
  child with `rootfs.storage` materializes by installing the bundled
  descriptor-bound rootfs block index and referenced rootfs chunk objects into
  the destination rootfs CAS cache; the exact ext4 digest-cache artifact is not
  required on the destination.
- `spore pack --children DIR --rootfs=metadata-only` can emit an indexed bundle
  with rootfs metadata but no rootfs bytes after verifying the source rootfs
  cache; `spore unpack` and `spore pull` accept it only with
  `--allow-metadata-only-rootfs` and a verified destination cache hit.
- Foundation Slice 6 has S3/SSM remote restore, host-local cache reuse,
  source-peer HTTP pull support, corrupt-bundle rejection, and ten-instance
  star/tree smoke evidence.
- `scripts/smoke-remote-bundle.sh --workload rootfs` extends the real-host
  remote bundle smoke beyond diskless spores: the source builds OCI rootfs
  bytes, packs either exact ext4 storage or `--rootfs-storage chunked` CAS
  storage into the indexed bundle, destinations pull into a fresh rootfs cache,
  repeated pulls prove rootfs cache reuse with `rootfs.cache.bytes_reused`,
  corrupt rootfs payloads are rejected, and destinations verify materialization
  through the selected child manifest and cache path.
- `scripts/validate-release-a1-kvm.sh` is the repeatable release-readiness
  wrapper for SSM-managed A1/KVM hosts. It runs a direct-S3 diskless bundle
  check with destination cache reuse, corrupt-bundle rejection, and KVM
  networking smokes, then runs chunked-rootfs CAS bundle checks over direct S3
  and HTTP peer pulls with destination cache reuse and corrupt rootfs rejection.
- `spore run --image`, `spore resume`, `spore fork`, and `spore fanout` support
  local immutable-rootfs fan-out.

## Delivery Strategy

### Slice 1: Default Rootfs Artifacts In Existing Bundles

Status: implemented for the existing single-spore bundle path.

Teach the existing single-spore bundle path to carry exact immutable rootfs
bytes by default. This closes the immediate gap for rootfs-backed remote resume
without waiting for multi-child bundle indexing.

Candidate commands:

```console
spore pack ruby.spore --out ruby.bundle/
spore unpack ruby.bundle/ --out ruby.unpacked.spore
spore resume ruby.unpacked.spore
```

Done when `spore pack` includes a verified `rootfs/blake3/<hex>.ext4` artifact
for rootfs-backed spores, `spore unpack` installs it into the destination digest
cache through an atomic verify-then-rename path, `bundle_digest` covers the
included rootfs bytes, and missing or corrupted rootfs bytes fail before VM
creation. Diskless spore bundles and existing chunkpack corruption tests must
continue to pass.

Slice 1 intentionally did not implement `--rootfs=metadata-only`, `bundle.json`,
or a multi-rootfs `rootfs.index.json` parser. The single-spore manifest was
enough to locate the required rootfs digest and canonical bundle path. Slice 2
then added indexed bundle metadata, `rootfs.index.json`, parser tests, fuzz
coverage, and the `SECURITY.md` attack-surface update.

### Slice 2: Distribution Bundle Index

Status: implemented for local `spore pack --children` and `spore unpack --child`
on filesystem bundles.

Add a bundle-level index that can name one parent manifest, many child
manifests, the chunkpack index, optional rootfs artifacts, and the bundle digest.
Keep the current one-spore `spore pack`/`spore unpack` behavior working while
adding the multi-child shape behind an explicit flag.

Candidate command:

```console
spore pack ruby.spore --children ruby.children/ --out ruby.bundle/
```

Done when a local bundle can contain a parent and a child table, mark rootfs
artifact policy for exact-byte versus metadata-only bundles, let `spore unpack`
or a test helper select a child, keep existing bundle verification rejecting
corrupt chunks and rootfs artifacts, and keep the legacy single-spore bundle path
covered. New bundle metadata parsers must be covered by unit tests, fuzz targets,
and a `SECURITY.md` attack-surface update.

### Slice 3: Local Pull Materialization

Status: implemented for local `file://` indexed bundles with a verified local
bundle content source and node-local chunk cache.

Add `spore pull` for filesystem bundles before adding remote stores. This should
verify the bundle, select a child, populate or reuse the node-local content
cache, and write a normal spore directory that `spore resume` already knows how
to run. The first version should fully materialize the child before resume; no
lazy remote reads should happen on the VM progress path.

Design this through a verified content-source interface rather than hard-coding
`spore resume` to only understand fully copied `chunks/<blake3>` directories.
For Slice 3, that interface can still have only local implementations.

Candidate command:

```console
spore pull file:///tmp/ruby.bundle --child 42 --out ruby-42.spore
```

Done when a local multi-child smoke pulls several children from one bundle,
shows shared chunks/rootfs bytes are not copied per child where the filesystem
supports linking, confirms every selected child's required bytes are present
before resume starts, and resumes each child through the product CLI. Unit tests
should cover the content-source boundary so later lazy sources can be added
without changing manifest semantics.

### Slice 4: Object-Store Push And Pull

Status: implemented for indexed S3 bundles through the AWS CLI adapter.

Add the first remote store adapter using S3, matching the existing S3/SSM remote
restore smoke path. An OCI-layout or registry transport can follow after the
descriptor shape settles.

Candidate commands:

```console
spore push ruby.bundle/ s3://sporevm-artifacts/runs/ruby.bundle/
spore pull s3://sporevm-artifacts/runs/ruby.bundle@sha256:<bundle> \
  --child 42 \
  --out ruby-42.spore
```

Done when two or more same-class Linux/KVM aarch64 hosts can independently pull
different children, reject corrupted remote data, and report origin bytes read
for the run. The direct-S3 path in `scripts/smoke-remote-bundle.sh` now uses
`spore push` on the source and digest-pinned `spore pull` on destinations.

### Slice 5: Node-Local Cache Reuse

Status: implemented for local and direct-S3 `spore pull` cache metrics.

Make repeated pulls on one host reuse already verified bundle, chunk, and rootfs
bytes by digest. This is the short-term answer to fan-out efficiency without
introducing a distributed peer protocol.

Done when pulling child 0 and child 1 from the same remote bundle on one host
does not re-fetch shared chunkpacks or rootfs artifacts, and metrics expose
bundle cache hits, chunk bytes fetched/reused, rootfs bytes fetched/reused, and
origin bytes. The product `pull` JSON now reports those counters directly.
Rootfs-backed unit and local pull smokes cover rootfs cache reuse; the direct-S3
real-host smoke can run `--dest-repeat 2 --cache-dir DIR` to pull different
children on one destination and assert the second pull reads zero origin and
chunk bytes while reporting reused rootfs bytes.

### Slice 6: Metadata-Only Prepared Rootfs

Status: implemented for indexed bundles with explicit prepared-cache
materialization.

Add the explicit rootfs artifact opt-out now that the exact-byte default is
working. This is for environments that prepare the immutable rootfs digest cache
out of band and want distribution bundles to carry memory and rootfs metadata
without carrying the ext4 payload.

Candidate commands:

```console
spore pack ruby.spore --children ruby.children/ --rootfs=metadata-only --out ruby.bundle/
spore pull file:///tmp/ruby.bundle \
  --child 42 \
  --allow-metadata-only-rootfs \
  --out ruby-42.spore
```

Done when metadata-only indexed bundles omit `rootfs/blake3/<hex>.ext4`, keep
the rootfs digest in `rootfs.index.json`, fail normal materialized unpack/pull,
fail the explicit allow path on an empty destination cache, and succeed only
when the destination cache already contains the verified rootfs digest.

### Slice 7: Digest-Pinned HTTP Peer Pull

Status: implemented for static HTTP(S) bundle peers behind `spore pull`.

Move source-peer and relay-peer transfer behind the product pull contract without
introducing a peer daemon or changing the trust model. A peer is only a byte
source: the bundle digest, selected manifest, BLAKE3 memory chunks, SHA256 pack
segments, and rootfs artifact digests remain the authority.

Candidate command:

```console
spore pull http://10.0.0.12:20000/spore.bundle@sha256:<bundle> \
  --child 42 \
  --out ruby-42.spore
```

Done when HTTP(S) pull sources require `@sha256:<bundle>`, reject mutable or
path-ambiguous URLs, download only canonical files named by validated bundle
metadata, verify the canonical bundle digest before writing `.complete`, report
`remote.peer_bytes_read`, hit the `remote/http/sha256/<bundle>` cache on
repeated pulls, and fail closed on corrupt peer bytes. The remote bundle smoke
now serves static bundle directories from source and relay hosts and uses product
`spore pull http://...@sha256:<bundle>` for peer star/tree paths.

### Slice 8: Chunked Rootfs Storage Bundles

Status: implemented for indexed bundles and complete materialization.

Teach the indexed bundle path to carry manifest-attached chunked rootfs storage
without falling back to the monolithic ext4 artifact. This extends the existing
verified bundle/cache story rather than adding a new pull mode.

Done when local, S3, and HTTP bundle file enumeration includes rootfs storage
indexes and chunk objects in the canonical bundle file set, bundle digest covers
those files, and `spore pull file://... --child ID` can materialize a selected
child into the node-local rootfs CAS cache while rejecting corrupt rootfs chunk
objects before writing a resumable spore. The real-host release wrapper now runs
chunked-rootfs bundle materialization over both direct S3 and HTTP peer pulls.

## Deferred Peer Distribution

Lazy-pull, cache-only preheat, peer discovery, gossip, DHTs, torrent scheduling,
range-level peer reuse, and scheduler-aware source selection are still deferred.
They can fit behind the same `pull` contract later, but the shipped product path
keeps the failure boundary simple: `pull` either materializes and verifies a
child, or it fails before `resume` starts.

The static HTTP(S) source is intentionally not a peer protocol. It is the first
peer-backed pull source because it proves the byte-source rule without adding
daemon state: peers can deny service or serve stale/corrupt bytes, but they
cannot become restore authority.

## Verification

- Unit tests for bundle index parsing, child selection, schema rejection,
  missing files, path traversal, duplicate child ids, and digest mismatches.
- Unit tests for the verified content-source interface: chunk lookup by digest,
  offset/length bounds, cache hits, missing chunks, and failed verification.
- Existing single-spore pack/unpack tests continue to pass unchanged.
- Unit tests for rootfs artifact inclusion, digest-cache preload, tampered rootfs
  bytes, descriptor type checks, and symlink handling.
- Unit tests for bundle-carried writable disk layers, bundle digest coverage for
  disk objects, S3 upload/download file lists, remote bundle cache reuse, and
  corrupt disk object rejection.
- Unit tests for atomic rootfs cache installation, concurrent cache hits, failed
  partial writes, and bundle digests changing when any rootfs artifact changes.
- Unit tests for chunked rootfs storage bundles: positive local pull into a
  fresh rootfs CAS cache, absence of monolithic ext4 cache installation, bundle
  digest coverage of rootfs storage files, and corrupt rootfs chunk rejection.
- Fuzz targets for new attacker-influenced bundle metadata parsers such as
  `bundle.json` and `rootfs.index.json`, in the same PR that introduces them.
- `SECURITY.md` updates for every slice that widens bundle, rootfs artifact, or
  remote-store parsing.
- Local smoke: fork one rootfs-backed workload, pack children, pull selected
  children from `file://`, and resume them with `mise run smoke:local-pull`.
- Remote smoke: push one bundle to S3, pull separate children on same-class
  Linux/KVM aarch64 hosts, resume them, record origin bytes, and use
  `--dest-repeat 2 --cache-dir DIR` to prove repeated direct-S3 pulls on one
  host reuse the remote bundle and chunk cache. Add `--writable-rootfs` to run
  the same path against a rootfs-backed writable disk bundle and report disk
  object count/bytes; run `writable-rootfs-20260619T212758Z` proved this on two
  `a1.metal` hosts.
- Peer remote smoke: serve a bundle from a source or relay host over HTTP,
  materialize destinations through `spore pull http://...@sha256:<bundle>`,
  resume selected children, and record peer bytes separately from origin bytes.
  Use the optional max-origin-egress multiplier flags when closing the
  foundation fan-out egress gate.
- Rootfs remote smoke: run `scripts/smoke-remote-bundle.sh --workload rootfs`
  against source/destination A1 hosts and confirm the output reports bundled
  rootfs payloads, cold destination rootfs bytes fetched, warm destination
  `rootfs.cache.bytes_reused` with zero refetch, corrupt rootfs rejection, and
  selected child materialization into the exact digest cache or chunked rootfs
  CAS cache. Add `--rootfs-storage chunked` to exercise manifest-attached
  rootfs CAS storage.
- Release wrapper: run `mise run validate:release-a1-kvm -- ...` or
  `scripts/validate-release-a1-kvm.sh -- ...` with SSM instance ids, bucket, and
  source peer IP to execute the direct-S3 diskless gate plus direct-S3 and
  HTTP-peer chunked-rootfs CAS cache-reuse/corrupt-rejection gates as one
  repeatable release check.
- Negative remote smoke: corrupt a bundle index, chunkpack segment, child
  manifest, and rootfs artifact, and confirm every path fails before VM boot.

## Resolved Decisions

- Distribution is pull-based. Schedulers place work; SporeVM materializes and
  verifies artifacts on the selected host.
- `pack`/`unpack` are local bundle operations. `push`/`pull` are remote store
  operations. `resume` executes a materialized spore.
- Rootfs-backed bundles include exact immutable rootfs bytes by default.
- Metadata-only rootfs bundles require an explicit opt-out and must be marked in
  bundle metadata; materialized unpack and pull accept them only with an
  explicit prepared-cache flag and a verified destination cache hit.
- Bundle digests cover all materialization-affecting bytes, including rootfs
  artifacts, so cache identity cannot ignore disk artifacts.
- Rootfs artifacts are installed into the local digest cache with atomic,
  verify-before-rename semantics.
- The first `spore pull` implementation fully materializes one selected child
  before `spore resume`.
- Lazy-pull is a core design constraint but not first shipped behavior. Complete
  materialization is the first policy on top of a lazy-capable verified content
  source.
- Rootfs bytes remain distinct from memory chunks even when both live in one
  bundle.
- Manifest-attached chunked rootfs storage is distributed as rootfs-specific
  CAS data: descriptor-bound rootfs indexes and chunk objects live under
  `rootfs/blake3`, are installed into the rootfs CAS cache, and remain distinct
  from RAM chunks and writable disk objects.
- Full child manifests are the first implementation target. Delta-encoded child
  manifests can wait until manifest size becomes material.
- Direct object-store transfer comes before peer-assisted transfer.
- S3 is the first remote store adapter because it matches the current remote
  smoke infrastructure; OCI-layout or registry transport is follow-up work.
- Multi-child bundling stays under `spore pack --children` until the artifact
  surface clearly outgrows `pack`/`unpack`.
- Digest-pinned HTTP(S) is the first peer-backed `pull` source. It has no
  discovery protocol; callers provide the peer URL, and SporeVM treats it as an
  untrusted byte source.

## Deferred Work

- Peer daemon, peer discovery, range-level peer scheduling, lazy remote reads,
  and cache-only preheat remain follow-up work behind the verified content
  source boundary.

## Key Learnings From Pressure-Testing

- Default metadata-only rootfs bundles are operationally fragile because a clean
  destination can verify the required digest from metadata but still lack the
  bytes needed to resume. The plan therefore keeps exact rootfs bytes as the
  default and requires explicit flags plus a verified prepared cache for
  metadata-only materialization.
- The first exact-rootfs slice correctly avoided depending on bundle metadata
  before that metadata existed. Indexed bundle metadata now exists for
  multi-child bundles, and metadata-only CLI behavior is constrained to indexed
  bundles with prepared destination caches.
- Bundle identity must cover rootfs artifacts. Per-rootfs BLAKE3 verification
  still protects resume, but cache keys and remote references are misleading if
  rootfs bytes are outside the bundle digest.
- Digest-cache writes need an atomic install protocol. A partially copied rootfs
  at its final digest path can race with resume or later pulls, so unpack/pull
  must verify temporary bytes before renaming into place.
- Including rootfs bytes can make bundles much larger, but that is a distribution
  cost, not a restore correctness reason to omit them. Dedupe by rootfs digest
  and node-local cache reuse are the intended mitigations.
- Full child manifests are less clever than deltas, but they keep the first
  loader simple and preserve today's restore path. Compression or delta encoding
  should wait until manifest size shows up in measurements.
- Peer-to-peer ideas are most useful as cache policy, not as a new trust model.
  Static HTTP(S) peers now supply bytes through `spore pull`, but manifests,
  chunk ids, bundle digests, and rootfs digests stay the authority.
