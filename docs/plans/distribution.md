---
status: active
last_reviewed: 2026-06-18
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
requires an immutable rootfs artifact, `spore pack` should include the exact ext4
bytes named by the rootfs digest unless the caller explicitly asks for a
metadata-only bundle for a prepared-cache workflow after bundle metadata supports
that mode.

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
- Writable disk distribution or persisted guest disk mutations.
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
`-- rootfs/blake3/<hex>.ext4        # optional exact immutable rootfs bytes
```

`manifest.json` and its BLAKE3 memory chunk ids remain the restore-time trust
root. The bundle index and SHA256 segment hashes are transport and cache
metadata. Rootfs artifacts stay separate from memory chunks: their manifest
section records `kind`, read-only mode, device binding, BLAKE3 digest, size, and
provenance, and `spore resume` must still verify the exact fd it will attach.

Rootfs inclusion is the default artifact policy:

- If any selected manifest records an immutable rootfs artifact, `spore pack`
  verifies the source digest-cache ext4 by BLAKE3 and size, then includes it in
  the bundle once per rootfs digest.
- If the required rootfs bytes are absent or mismatched on the packing host,
  `spore pack` fails rather than emitting a misleading portable bundle.
- Slice 1 has no metadata-only mode: a rootfs-backed spore either packs exact
  rootfs bytes or fails. Metadata-only rootfs bundles require bundle metadata and
  therefore land no earlier than the bundle-index slice.
- `spore unpack` and `spore pull` install bundled rootfs artifacts into the
  node-local digest cache by default, verifying digest and size before writing a
  resumable spore.
- A metadata-only bundle may be unpacked only when the destination cache already
  has the required verified rootfs bytes, or when the caller explicitly chooses a
  non-resumable/preload-only operation.

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
  `manifest.json`, bundle indexes, chunkpack blobs, rootfs indexes, and included
  rootfs ext4 artifacts, in a canonical order.
- Bundle chunkpacks remain seekable by chunk id, offset, and length. Avoid a
  distribution format that requires downloading or decompressing the whole bundle
  before one referenced chunk can be verified.
- Rootfs artifacts are exact bytes, opened read-only, checked by BLAKE3 and
  size, included by default for portable bundles, and kept distinct from memory
  chunkpacks.
- Rootfs cache installation is atomic and symlink-safe: write a temporary
  regular file outside the final digest path, verify size and BLAKE3, set the
  final permissions, then rename into the digest-addressed cache path.
- `spore pull` refuses path traversal, unknown bundle schema versions, missing
  child manifests, digest mismatches, and incompatible platform contracts before
  writing a resumable spore.
- Corrupt origin, cache, or peer data fails closed in the same way.

## Current State

- `spore pack` and `spore unpack` round-trip one portable memory bundle with
  `manifest.json`, `chunkpack.index.json`, chunkpacks, `bundle_digest`, and
  chunk verification.
- Foundation Slice 6 has S3/SSM remote restore, host-local cache reuse,
  source-peer HTTP seeding, corrupt-bundle rejection, and ten-instance star/tree
  smoke evidence.
- `spore run --image`, `spore resume`, `spore fork`, and `spore fanout` support
  local immutable-rootfs fan-out.
- Rootfs identity is in the spore manifest, but exact rootfs bytes are not inside
  current bundles.
- Current `spore pack` accepts one spore directory and has no `--children`,
  `push`, `pull`, or rootfs artifact policy.

## Delivery Strategy

### Slice 1: Default Rootfs Artifacts In Existing Bundles

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

Slice 1 intentionally does not implement `--rootfs=metadata-only`, `bundle.json`,
or a multi-rootfs `rootfs.index.json` parser. The single-spore manifest is enough
to locate the required rootfs digest and canonical bundle path. If implementation
does add a new attacker-influenced rootfs index in this slice, it must update
`SECURITY.md` and add a fuzz target in the same PR.

### Slice 2: Distribution Bundle Index

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

Add the first remote store adapter using the simplest store that matches current
smokes. S3 is the likely first choice because the existing remote restore
evidence already uses S3 and SSM; an OCI-layout or registry transport can follow
after the descriptor shape settles.

Candidate commands:

```console
spore push ruby.bundle/ s3://sporevm-artifacts/runs/ruby.bundle/
spore pull s3://sporevm-artifacts/runs/ruby.bundle@sha256:<bundle> \
  --child 42 \
  --out ruby-42.spore
```

Done when two or more same-class Linux/KVM aarch64 hosts can independently pull
different children, reject corrupted remote data, and report origin bytes read
for the run.

### Slice 5: Node-Local Cache Reuse

Make repeated pulls on one host reuse already verified bundle, chunk, and rootfs
bytes by digest. This is the short-term answer to fan-out efficiency without
introducing a distributed peer protocol.

Done when pulling child 0 and child 1 from the same remote bundle on one host
does not re-fetch shared chunkpacks or rootfs artifacts, and metrics expose
bundle cache hits, chunk bytes fetched, rootfs bytes fetched, and origin bytes.

## Deferred Peer Distribution

Lazy-pull and cache-only preheat are also deferred. They can fit behind the same
`pull` contract later, but the first product path should keep the failure
boundary simple: `pull` either materializes and verifies a child, or it fails
before `resume` starts. The code should still preserve a lazy-capable resolver
boundary so this deferred work is an additional source policy, not a rewrite of
bundle parsing or resume.

Peer-assisted transfer can fit behind the same `pull` contract later. The useful
ideas from Dragonfly, Nydus, torrent systems, and gossip protocols are local:
content-addressed verification, range-level reuse, pull-through node caches,
preheating, and scheduler-aware source selection.

Do not build a peer protocol until direct object-store pull has numbers that
show origin egress is the bottleneck. A later peer slice should keep the same
rule: peers are byte sources, not trust roots.

## Verification

- Unit tests for bundle index parsing, child selection, schema rejection,
  missing files, path traversal, duplicate child ids, and digest mismatches.
- Unit tests for the verified content-source interface: chunk lookup by digest,
  offset/length bounds, cache hits, missing chunks, and failed verification.
- Existing single-spore pack/unpack tests continue to pass unchanged.
- Unit tests for rootfs artifact inclusion, digest-cache preload, tampered rootfs
  bytes, descriptor type checks, and symlink handling.
- Unit tests for atomic rootfs cache installation, concurrent cache hits, failed
  partial writes, and bundle digests changing when any rootfs artifact changes.
- Fuzz targets for new attacker-influenced bundle metadata parsers such as
  `bundle.json` and `rootfs.index.json`, in the same PR that introduces them.
- `SECURITY.md` updates for every slice that widens bundle, rootfs artifact, or
  remote-store parsing.
- Local smoke: fork one rootfs-backed workload, pack children, pull selected
  children from `file://`, and resume them.
- Remote smoke: push one bundle to S3, pull separate children on same-class
  Linux/KVM aarch64 hosts, resume them, and record origin bytes.
- Negative remote smoke: corrupt a bundle index, chunkpack segment, child
  manifest, and rootfs artifact, and confirm every path fails before VM boot.

## Resolved Decisions

- Distribution is pull-based. Schedulers place work; SporeVM materializes and
  verifies artifacts on the selected host.
- `pack`/`unpack` are local bundle operations. `push`/`pull` are remote store
  operations. `resume` executes a materialized spore.
- Rootfs-backed bundles include exact immutable rootfs bytes by default.
- Metadata-only rootfs bundles require an explicit opt-out and must be marked in
  bundle metadata; they do not exist in the first exact-rootfs bundle slice.
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
- Full child manifests are the first implementation target. Delta-encoded child
  manifests can wait until manifest size becomes material.
- Direct object-store transfer comes before peer-assisted transfer.

## Open Questions

- The exact metadata-only opt-out spelling is not blocking Slice 1 because
  metadata-only mode is deferred until bundle metadata exists.
  Recommendation: use `--rootfs=metadata-only` rather than `--exclude-rootfs`
  because it names the artifact policy and leaves room for future modes.
- Should the first remote transport be S3-only, generic object storage, or an
  OCI-layout/registry adapter? Recommendation: land S3 first because the current
  smoke path already proves it, then map the stable descriptor shape to OCI.
- Should multi-child bundling stay under `spore pack --children` or become a new
  subcommand later? Recommendation: keep `pack` until the local artifact surface
  clearly outgrows it.

## Key Learnings From Pressure-Testing

- Default metadata-only rootfs bundles are operationally fragile because a clean
  destination can verify the required digest but still lacks the bytes needed to
  resume. The plan therefore makes exact rootfs bytes the default and reserves
  metadata-only behavior for a later explicit prepared-cache workflow with
  bundle metadata.
- The first exact-rootfs slice must not depend on bundle metadata that does not
  exist yet. It uses the single-spore manifest and canonical rootfs path, while
  deferring metadata-only policy and multi-rootfs indexes to the bundle-index
  slice.
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
  Peers can supply bytes later, but manifests, chunk ids, and rootfs digests stay
  the authority.
