---
status: active
last_reviewed: 2026-07-23
spec_refs:
  - docs/image-gateway-protocol.md
  - docs/filesystem.md
  - docs/rootfs.md
  - docs/spore-build.md
  - docs/spore-format.md
  - SECURITY.md
  - src/build.zig
  - src/image.zig
  - src/rootfs.zig
  - src/rootfs/oci.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/runtime_disk.zig
  - src/chunk_mapped_disk.zig
  - src/block_source.zig
  - src/bundle.zig
related_plans:
  - docs/plans/spore-build.md
---

# Spore Image Gateway

## Summary

Build a mediated service that converts each selected OCI platform image into
Spore's native image form once, then distributes that verified result to every
compatible SporeVM host that is authorized to use it. A gateway tag names an
immutable platform index whose `linux/arm64` and `linux/amd64` entries point to
separate native image manifests. The target client selects one platform, pulls
its canonical rootfs index, and transfers the rootfs chunks absent from its
local CAS. G0 may select a simpler static archive for the first cold-path proof
if partial-cache reuse does not justify a custom batch protocol yet. Either path
installs verified bytes through the existing rootfs-cache transaction and
publishes a platform-scoped local image ref, after which current `spore run`,
`spore create`, and `spore build FROM local/...` use their existing paths
unchanged.

The eager gateway is an image control and distribution plane, not runtime
authority. The local rootfs index, BLAKE3-verified objects, completeness stamp,
image metadata, and local ref remain authoritative on the client. A remote tag
or gateway response is only a way to discover and fetch immutable bytes. The
protocol still keeps every rootfs object independently addressable and
authorization-bound so a later explicit lazy mode can use the same manifest and
index as verified remote content-source authority without changing native image
identity or the guest-visible block device.

The first product slice is deliberately explicit:

```bash
spore image pull \
  --gateway https://gateway.example \
  --platform linux/arm64 \
  --repository team/base-images \
  --ref local/alpine:gateway \
  docker.io/library/alpine:3.20

spore run --image local/alpine:gateway --pull=never -- /bin/true
```

It supports allowlisted public OCI sources, one gateway deployment, and both
`linux/arm64` and `linux/amd64`. The protocol, conversion service, repository
tags, and fixtures are multi-platform from G0; end-to-end x86 execution joins
the acceptance matrix as the x86_64 runtime backend lands. It proves cross-host
conversion reuse and the eager image transport before `spore run --image` or
`spore build` gains transparent gateway lookup. Native `spore build` push,
private upstream credentials, multi-tenancy, remote-on-fault reads, prepared
build bases, and shared Dockerfile step records are later and separately gated
work.

## Problem

SporeVM's image and build paths are locally fast but machine-local. OCI images
are converted into a deterministic ext4 filesystem, sealed into 64 KiB BLAKE3
objects, published as a canonical versioned disk index, and then cached under
a local ref. `spore build` also checkpoints each rootfs-changing instruction
through that same CAS and publishes its final rootfs index plus canonical image
configuration as a local Spore image.

This is the right runtime representation, but every empty host repeats the OCI
edge work: registry resolution, layer download and verification, tar and
whiteout application, deterministic ext4 production, chunk hashing, object
publication, and index publication. The current builder plan records a
148.78-second forced-cold build versus a 9.87-second warm rebuild and a
7.31-second one-file incremental rebuild. Those timings are historical
motivation rather than the gateway acceptance baseline; G0 remeasures exact
current binaries and records durable phase evidence. A gateway cannot make a
clean host warm, but it can replace repeated conversion with bounded verified
transfer.

Existing distribution does not close this gap:

- local image refs and Dockerfile step records are deliberately host-local;
- `spore pack`, `push`, and `pull` distribute saved-machine bundles rather than
  named immutable images, and the current S3 path uploads canonical files one
  at a time;
- an ordinary OCI pull-through mirror caches source manifests and layers but
  does not produce Spore rootfs indexes or objects;
- exporting `spore build` back into OCI layers would discard the native image
  identity and make another host reconstruct the same filesystem.

The product gap is a service that owns conversion admission, immutable image
discovery, efficient CAS transfer, and repository policy while preserving the
client's existing verification and publication boundary.

The current runtime and builder still fail closed outside arm64, but platform
already participates in OCI selection and local image-ref cache keys. With an
x86_64 backend planned, an arm64-only gateway schema would turn a known product
requirement into a repository migration. Multi-platform tags and per-platform
native manifests therefore belong in the first gateway contract even if the
arm64 runtime preview becomes usable first.

## Goals

- Convert each selected OCI platform manifest once per explicit conversion
  contract and reuse the result across hosts.
- Treat `linux/arm64` and `linux/amd64` as core platform values in the first
  protocol, conversion key, repository tag, local-ref, and conformance design.
  The shared product `Architecture` type maps OCI `amd64` to the future
  `x86_64` machine backend only at the runtime boundary.
- Let one gateway repository tag atomically describe the available
  per-platform image manifests without mixing entries from different
  generations of a mutable upstream OCI index.
- Make gateway conversion produce the same canonical rootfs index bytes and
  exact canonical image-config JSON bytes as direct local OCI conversion pinned
  to the same conversion contract. Gateway install then publishes the normal
  indexed-image identity over those two values.
- Distribute native `spore build` and `spore run --commit` image results after
  the pull-through path is proven.
- Let clients avoid downloading chunks already present in their rootfs CAS.
- Bound request count independently of rootfs chunk count.
- Resolve mutable OCI tags centrally into recorded digest-pinned provenance.
- Mediate which source registries, repositories, platforms, and gateway
  repositories a caller may access.
- Preserve `--pull=missing|always|never` semantics when transparent integration
  lands.
- Keep corrupt remote state unreachable everywhere. G1 also keeps incomplete
  storage unreachable from local refs, build bases, saved manifests, and
  runtime disks; G5 may expose only an explicitly remote-backed image after its
  immutable manifest, config, rootfs index, authorization, and retention lease
  are verified.
- Report conversion, transfer, reuse, and install timings well enough to prove
  whether the gateway is faster than direct OCI conversion.
- Keep the service backend-neutral: object storage, registry-compatible blob
  storage, or a filesystem backend must not change the client protocol or
  image identity.
- Keep the eager pull path compatible with future lazy pull: the immutable
  manifest and index identify every chunk independently, the service can fetch
  one authorized object by digest, and static archives remain optional transfer
  accelerators rather than the only storage authority.
- Keep physical CAS dedupe private to the service. Every public object lookup,
  missing-set query, upload, and attachment operation is authorized through a
  repository plus immutable manifest or proposed-manifest closure rather than a
  global digest namespace.
- Make signatures, SBOMs, extended conversion records, and other provenance
  typed immutable attachments to an immutable gateway image manifest, managed
  transactionally by the service and excluded from native image identity.

## Non-Goals

- No remote Dockerfile step cache in this plan. A step record asserts that a
  semantic transition produces a child rootfs and needs a stronger trust and
  poisoning model than distributing a content-verified final image.
- No OCI layer exporter for `spore build`.
- No claim that a gateway pull equals a fully warm local cache; a clean client
  still transfers and installs the bytes it lacks.
- No remote rootfs object reads on the virtio-blk I/O path in the first
  version. Runtime I/O continues to fault only from a complete local CAS, but
  G0/G1 must not choose a manifest, authorization, or storage contract that
  prevents a later remote content source from supplying one verified object.
- No saved-machine, RAM, device-state, or session distribution. Existing
  `spore pack`, `push`, and `pull` retain that contract.
- No generic OCI Distribution conformance requirement. OCI is the input edge;
  the native output protocol is optimized for Spore's index and object model.
- No repository-independent blob `HEAD`, unrestricted digest lookup, global
  missing-object query, or cross-repository mount API. Physical cross-image or
  cross-repository dedupe never becomes a caller-visible authorization surface.
- No derived or reserved tag names for signatures, SBOMs, provenance indexes,
  or other attachments, and no client-maintained read-modify-write attachment
  list. Mutable tags select platform indexes only.
- No public anonymous conversion endpoint, arbitrary URL fetcher, or open
  proxy.
- No private upstream credentials or multi-tenant dedupe in the first product
  slice.
- No centrally prepared 16 GiB Dockerfile base in the first slice. PREPARE
  depends on an exact parent, target, platform, kernel/initrd, and growth
  protocol identity and remains local until its incremental value is measured.
- No new rootfs index, chunk, image identity, or manifest authority format.
- No claim that `gateway-required` prevents a local operator from importing
  already-local OCI layouts or rootfs tarballs. It governs managed remote image
  resolution; host-level egress enforcement belongs to deployment network
  policy, not a cooperative CLI option.

## Ownership Boundaries

SporeVM owns:

- the native image identity and canonical image configuration;
- normalized image-platform selection using OCI `arm64` and `amd64` names;
- rootfs storage descriptor and disk-index validation;
- the gateway platform index, image manifest, and object-transfer wire parsers
  used by the client;
- remote byte verification, local CAS installation, completeness, metadata,
  and local-ref publication;
- a bounded optional gateway-provenance record stored beside indexed-image
  metadata but excluded from canonical image identity;
- typed attachment descriptors and subject binding used by inspection and
  policy without making attachments native content authority;
- CLI behavior and pull-policy integration;
- conformance fixtures shared with a gateway implementation.

The client implementation reuses `src/architecture.zig`: protocol and image
types carry `arm64` or `amd64`, then backend selection calls its exhaustive
`selectBackend` mapping. The gateway must not add a parallel
runtime-architecture enum with `aarch64` or `x86_64` product tags.

The gateway service owns:

- caller authentication and gateway repository authorization;
- OCI source policy, tag resolution, upstream credentials, and egress policy;
- conversion single-flight, worker scheduling, quotas, and failure caching;
- durable platform indexes, image manifests, canonical rootfs indexes, chunk
  objects, and mutable gateway tags;
- transfer batching, retention, garbage collection, and audit logs;
- atomic server-owned subject-to-attachment relations and attachment retention;
- signing or attesting the source-to-output conversion record when that policy
  is enabled.

The initial service should live separately from the SporeVM runtime. Its
deployment, identity provider, object-store credentials, queues, and retention
policy have a different lifecycle and attack surface. This plan defines the
cross-repository contract; golden manifests, batch frames, and rejection cases
must be exercised by both implementations before either side changes the
protocol.

## Identity Model

### Source identity

The gateway resolves a requested OCI ref and normalized platform to both the
top-level OCI index digest and selected platform manifest before looking up or
starting conversion. Platform values use OCI vocabulary: `linux/arm64` and
`linux/amd64`; `x86_64` is a SporeVM machine/backend name and never appears in
OCI selection or canonical image configuration. The conversion cache key is
the canonical tuple:

```text
selected OCI manifest sha256
platform os/arch
rootfs builder version
ext4 writer contract
```

G0 freezes variant normalization rather than silently taking the first matching
OCI descriptor. For v1, `linux/arm64` accepts an absent or `v8` descriptor
variant and normalizes it to arm64 only when selection is unambiguous;
`linux/amd64` requires no variant. Other or ambiguous variants fail closed until
the platform model explicitly supports them.

The requested tag is provenance and mutable-alias state, not conversion
identity. The selected manifest already binds the OCI config and layer
descriptors. The conversion contract is a structured pair, not a newly invented
opaque string: the current rootfs `builder_version` plus exact writer text. The
builder version changes whenever accepted OCI semantics or deterministic output
bytes can change. G0 pins the native writer, checks that the current writer
contract is fit for remote reuse, and generates cross-implementation fixtures
before a second implementation depends on it. The worker binary digest is
recorded for audit but does not fragment the cache when two binaries implement
the same conversion contract. Worker host architecture is likewise audit
metadata rather than target identity: an arm64 and amd64 worker implementing the
same contract must emit identical bytes for the same selected target manifest.

A tag refresh that resolves to an existing selected-manifest digest reuses the
existing conversion. For a multi-platform source tag, the gateway records the
top-level OCI index digest and never combines per-platform conversions selected
from different top-level digests into one gateway tag generation. A tag that
moves publishes a new immutable platform index before its mutable gateway alias
changes atomically.

### Native image identity

The output reuses SporeVM's current indexed-image identity: the BLAKE3 rootfs
`index_digest` plus the exact canonical image-config JSON bytes determine the
immutable image digest. The gateway carries those canonical bytes verbatim as
a separate bounded blob; it never reconstructs them from a renamed or nested
gateway JSON object. OCI provenance, gateway repository, requested tag,
converter worker, timestamps, and signatures do not enter that digest.

This distinction allows the same native image to be reached from an OCI source,
a native `spore build`, or `spore run --commit` without renaming its filesystem
or image configuration. Provenance remains attached metadata and may differ
across equivalent outputs. Direct OCI import currently publishes OCI cache-key
metadata rather than the BLAKE3 indexed-image metadata used by `spore build` and
`run --commit`; gateway correctness therefore compares canonical index and
config bytes with direct conversion, then verifies the indexed-image digest it
publishes locally.

Architecture is part of the canonical OCI image config, so arm64 and amd64
outputs have distinct native image identities even if their rootfs index bytes
happen to match. The local ref cache is already keyed by platform; G0 locks that
behavior with fixtures so the same textual local tag can safely resolve to
different native image digests for arm64 and amd64.

## Gateway Platform Index

Every mutable gateway tag resolves to an immutable, bounded platform index. A
single-platform tag is still represented as an index with one descriptor so
clients and repositories never need a second tag shape:

```json
{
  "kind": "spore-image-gateway-index-v1",
  "source_index_digest": "sha256:<top-level-oci-index-or-manifest>",
  "manifests": [
    {
      "platform": { "os": "linux", "arch": "amd64" },
      "manifest_digest": "sha256:<gateway-image-manifest>",
      "image_digest": "blake3:<indexed-image-digest>"
    },
    {
      "platform": { "os": "linux", "arch": "arm64" },
      "manifest_digest": "sha256:<gateway-image-manifest>",
      "image_digest": "blake3:<indexed-image-digest>"
    }
  ]
}
```

Descriptors are sorted by normalized platform and duplicate platforms are
invalid. The index records one upstream source generation when it represents an
OCI tag; native repositories may omit that provenance while preserving the
same descriptor shape. Platform selection happens before downloading config,
rootfs index, or object data. Unsupported or absent platforms fail closed and
never fall back to another architecture.

## Gateway Image Manifest

The gateway returns a bounded canonical JSON document named by its SHA-256
transport digest. SHA-256 is transport addressing for compatibility with
ordinary blob stores and the existing bundle-digest precedent; BLAKE3 remains
the native config, image, index, and chunk identity. The manifest carries
Spore's immutable identity rather than creating a second rootfs format:

```json
{
  "kind": "spore-image-gateway-manifest-v1",
  "image": {
    "digest": "blake3:<indexed-image-digest>",
    "platform": { "os": "linux", "arch": "arm64" },
    "config_blob": {
      "transport_digest": "sha256:<canonical-config-json>",
      "config_digest": "blake3:<indexed-image-config-digest>",
      "bytes": 37
    },
    "rootfs_storage": {
      "kind": "chunked-ext4-rootfs-v0",
      "device": {
        "kind": "virtio-mmio",
        "role": "rootfs",
        "virtio_device_id": 2,
        "mmio_slot": 1
      },
      "logical_size": 65537,
      "chunk_size": 65536,
      "hash_algorithm": "blake3",
      "index_digest": "blake3:<rootfs-index-digest>",
      "base_identity": "blake3:<rootfs-index-digest>",
      "object_namespace": "rootfs/blake3"
    }
  },
  "source": {
    "kind": "oci-image",
    "requested_ref": "docker.io/library/alpine:3.20",
    "resolved_ref": "docker.io/library/alpine@sha256:<manifest>",
    "source_index_digest": "sha256:<top-level-index-or-manifest>",
    "selected_manifest_digest": "sha256:<manifest>",
    "conversion_contract": {
      "rootfs_builder": "sporevm-rootfs-v6",
      "ext4_writer": "native"
    }
  },
  "rootfs_index": {
    "digest": "blake3:<rootfs-index-digest>",
    "bytes": 449,
    "object_count": 2,
    "object_bytes": 65537
  }
}
```

The durable schema carries every current `RootfsStorage` field, including the
complete virtio-mmio device binding. The parser rejects unknown kinds and
versions, duplicate fields, invalid
UTF-8, trailing input, non-canonical digests, unsupported platform or storage
values, inconsistent index/base identities, oversized configuration, and
values beyond current local rootfs/index bounds.

The manifest references the canonical v1 or v2 disk index; it does not repeat
the index's logical-chunk map. The client fetches the canonical config blob,
verifies its SHA-256 transport digest and BLAKE3 config digest, parses it as the
current `ImageConfig`, serializes it through the canonical writer, and requires
byte-for-byte equality. It then verifies the rootfs index BLAKE3 digest, the
index's full-coverage invariants, and the current native image digest over the
index plus those exact canonical config bytes.
The selected platform-index descriptor, image-manifest platform, and canonical
config `os` and `architecture` must agree exactly after v1 normalization. This
schema and verification path now feed the explicit eager-client proof, which
uses manifest-bound single-object GETs and the ordinary local CAS publication
transaction. The verifier also binds optional source provenance to the platform
index's source generation, so a mutable upstream tag cannot produce a mixed-
generation multi-platform index.

## Provenance And Attachments

The gateway image manifest keeps the bounded source and conversion record needed
to explain how its native image was produced. Larger or independently produced
material—conversion attestations, signatures, SBOMs, vulnerability reports, and
policy results—uses a typed attachment relation whose subject is the immutable
gateway image-manifest digest, never a mutable tag.

An attachment record is immutable and contains only a protocol kind, exact
subject manifest digest, supported artifact type, and bounded artifact
descriptor with media type, byte size, and SHA-256 transport digest. The
artifact may sign or describe native BLAKE3 identities inside its own payload,
but neither the record nor artifact bytes enter native image, rootfs, or
platform-index identity. Unknown attachment record kinds fail closed; policy
decides which known artifact types it understands.

The service owns the subject-to-attachment relation. Publication writes and
verifies artifact bytes first, publishes the immutable attachment record
second, and atomically adds that record to the subject relation last. Listing is
bounded, deterministically ordered, filterable by supported artifact type, and
may return multiple records of the same type. There is no mutable "selected"
provenance record: policy evaluates the immutable records and issuers it trusts.
Clients never construct a special tag, fetch an attachment-index tag, or
perform a read-modify-write update of the relation.

Repository authorization applies to both the subject and attachment. A subject
roots its related attachments according to repository retention, while an
attachment never keeps a deleted or unreferenced subject alive. Failed or
abandoned attachment publication leaves only unreachable verified bytes for
later GC. G0 freezes these relation and envelope semantics so the protocol does
not need a compatibility tag scheme later; G3 implements attachment upload,
listing, inspection, policy, deletion, and retention.

## Control And Data Protocol

### Resolve or convert

The control request is idempotent and always names one normalized platform:

```http
POST /v1/conversions
Authorization: Bearer <gateway credential>
Content-Type: application/json

{
  "source_ref": "docker.io/library/alpine:3.20",
  "platform": { "os": "linux", "arch": "arm64" },
  "conversion_contract": {
    "rootfs_builder": "sporevm-rootfs-v6",
    "ext4_writer": "native"
  }
}
```

- `200 OK` returns an immutable ready manifest descriptor.
- `202 Accepted` returns a bounded operation id and `Retry-After`; polling does
  not start another conversion.
- `401` and `403` distinguish missing authentication from denied gateway or
  source policy without revealing private repository existence.
- unsupported registry, platform, media type, conversion contract, or image
  bound fails permanently and does not publish an alias.
- transient upstream or worker failure remains retryable and cannot poison the
  immutable conversion key indefinitely.

Only one worker may publish a conversion key. Objects, canonical config, and the
canonical rootfs index become durable first, the immutable per-platform gateway
manifest second, an immutable platform index after all selected entries are
ready, and a mutable tag or source alias last. Platform-index publication uses
compare-and-swap against the resolved upstream index generation so concurrent
arm64 and amd64 conversions cannot publish a mixed-generation tag. A losing
worker verifies and reuses the winner's immutable result rather than
overwriting it.

An operator can tombstone a poisoned conversion key, retain its audit record,
and force reconversion with the same declared contract. The service also
reconverts a sample of pinned fixtures with current workers and compares config
and index digests, catching a buggy worker or an unbumped conversion contract
before it becomes a fleet-wide cache hit.

### Pull

The client resolves and validates the immutable platform index, selects exactly
one requested platform, then fetches its image manifest, canonical config, and
canonical rootfs index. It checks every nonzero index digest against its local
CAS. If G0 selects missing-object transfer for G1, it splits only the absent
digests into bounded batch requests:

```http
POST /v1/objects:batchGet
Authorization: Bearer <gateway credential>
Content-Type: application/json

{
  "repository": "team/base-images",
  "gateway_manifest_digest": "sha256:<gateway-manifest>",
  "rootfs_index_digest": "blake3:<rootfs-index>",
  "namespace": "rootfs/blake3",
  "digests": ["blake3:<chunk>"]
}
```

The gateway authorizes the repository and immutable manifest, verifies the
requested index belongs to that manifest, and requires every distinct requested
digest to be reachable from that index. Authentication to a repository never
grants an arbitrary read oracle over the physical global CAS.

Protocol v1 also defines a single-object form for the future lazy content-source
boundary:

```http
GET /v1/repositories/team/base-images/manifests/sha256:<manifest>/objects/blake3:<chunk>
Authorization: Bearer <gateway credential>
```

It applies the same repository, manifest, index-reachability, size, and digest
checks as the batch endpoint. G1 implements and exercises this endpoint even if
its eager client uses a static archive, because an archive is a transfer
optimization rather than the only durable representation of image content.

There is no public `/blobs/<digest>` or `/objects/<digest>` namespace, generic
blob `HEAD`, cross-repository mount, or repository-wide existence query. A
missing, unauthorized, or manifest-unreachable digest produces the same
non-disclosing data-plane result after authentication; detailed classification
is available only in authorized audit events. Repository-internal physical
dedupe may satisfy a valid request without copying bytes, but that decision is
not observable as a separate protocol operation.

The response is a versioned, length-framed binary stream containing complete
objects. Server capabilities bound digest count, request bytes, response bytes,
client concurrency, and server concurrency; the first implementation should
start with at most 1,024 64 KiB objects and 64 MiB of payload per response, then
tune from measurements. G0 defines deterministic request splitting and a small
bounded concurrency default so client implementations do not accidentally turn
the batch endpoint back into unbounded fan-out. The server may source individual
chunks from filesystem or object storage and compose a batch without changing
their identities.

Batching preserves per-chunk server dedupe and local missing-object reuse while
avoiding one HTTP request per 64 KiB object. Its advantage over a static
per-image packfile is that unrelated image revisions can reuse local chunks;
its cost is a custom serving path and more gateway work. OCI artifact or
registry-compatible adapters remain possible later, but G0 first establishes
the request-count, byte-reuse, and storage measurements needed to choose the G1
transport.

Dynamic batches concentrate egress and composition work in the gateway, are not
generally CDN-cacheable, and can still cause one backend object-store read per
chunk. Backend neutrality applies to correctness and client protocol, not equal
cost. G1 records backend request count, bytes, composition CPU, and gateway
egress; those signals decide whether static packs, range reads, redirects, or a
local-NVMe serving tier move forward.

If G0 selects a static archive for G1, the archive is an immutable transport
object containing the same manifest-selected config, index, and objects. The
client still verifies and installs each native object independently, but it may
download bytes already present locally. Static archive layout remains
rebuildable transport metadata and does not enter rootfs or image identity.

The client verifies each object against the requested BLAKE3 digest before it
enters the cache. A duplicate, unexpected, missing, oversized, truncated, or
trailing batch entry fails the batch. Successfully verified objects may be
retained across a later batch failure, but the rootfs index, completeness
stamp, image metadata, and destination ref remain unpublished until the whole
storage value is complete.

### Push

Native push is a later slice:

```bash
spore image push \
  --gateway https://gateway.example \
  local/project:dev \
  team/project:dev
```

The client resolves the local ref before network I/O and opens a bounded upload
transaction containing the proposed platform, canonical config descriptor,
rootfs storage descriptor, and index descriptor. It uploads the canonical index
into private transaction staging first; the gateway verifies and parses it to
derive the complete reachable object set before returning a missing subset. The
client cannot probe arbitrary digests or a different repository through the
session. Missingness is computed from logical reachability in the authorized
destination repository, never from physical presence in another repository or
tenant. The client uploads that subset and the canonical image configuration;
the gateway independently validates every digest and descriptor, publishes the
objects, staged canonical index, config, and immutable image manifest in that
order, then atomically replaces the destination tag. Cross-repository physical
reuse may discard an already stored byte-identical upload after verification,
but it is never a mount request or existence response. The destination tag
never becomes authority for incomplete storage.

## Eager Client Installation Transaction

Network I/O must not hold the coarse local rootfs-cache lock. The client:

1. resolves the gateway response and validates its bounded manifest;
2. downloads canonical config, the canonical index, and apparently missing
   objects into a private staging directory, verifying every fetched digest as
   bytes arrive;
3. takes the existing exclusive rootfs-cache lock and removes any invalid
   completeness stamp before repairing entries;
4. re-verifies every referenced existing or staged object and the canonical
   index through the current CAS install APIs, rather than trusting the earlier
   unlocked presence probe;
5. if GC removed an object that appeared present and was therefore not staged,
   releases the lock, fetches the new missing set, and retries the locked phase
   once; a second race fails explicitly without publication;
6. installs objects, then the canonical index, then the derived completeness
   stamp;
7. calls indexed-image publication with the exact canonical config bytes,
   writes bounded gateway provenance beside that metadata, and atomically
   updates the requested local ref last;
8. releases the lock and removes staging state.

A crash before step 6 leaves only unreachable verified CAS data, which normal
GC may collect. Existing valid objects win over identical staged objects. A
same-path wrong-sized, symlinked, non-regular, or digest-mismatched cache entry
fails closed through the current install policy rather than being trusted or
silently replaced outside the cache transaction.

Staging lives under a private operation directory with a bounded manifest,
creation time, and retry identity. A later invocation may reuse only fully
verified staged objects for the same immutable gateway manifest. Startup and a
dedicated cleanup path remove expired or malformed operation directories; rootfs
CAS GC does not own staging cleanup.

The installed metadata must remain usable by current `spore run --image`,
`spore create --image`, `spore build FROM local/...`, cache GC, system prune,
and bundle pack without teaching those consumers about the gateway. Gateway
provenance is excluded from native identity and cache lookup; G0 decides whether
a later saved-spore manifest surfaces it or retains it only in image inspection
and gateway audit output.

## Lazy-Pull Compatibility

G1 still materializes a complete local CAS before publishing an ordinary image
ref. It does not mark partial storage complete and does not perform network I/O
from the virtio-blk path. That is the simplest reliable first policy.

The underlying format is already suitable for a later lazy mode: the canonical
rootfs index maps each logical chunk to a BLAKE3 object, and `ChunkMappedDisk`
already faults verified local CAS chunks into a sparse runtime base on first
read. G5 extends that existing missing-object boundary with an
authorization-bound remote content source; it does not introduce a second
rootfs index, image identity, guest device, or chunk namespace.

The future runtime contract is explicit:

- the platform index, selected image manifest, canonical config, and rootfs
  index are fetched and verified before VM creation;
- a remote-backed availability record is separate from the current local
  completeness stamp, which remains proof that every referenced object is
  installed locally;
- a missing object is fetched by immutable manifest plus digest, verified with
  BLAKE3, installed atomically into the local CAS, and promoted through one
  per-digest single-flight before the blocked read continues;
- locally present objects always win, and successful faults become ordinary CAS
  hits for later VMs without changing native image identity;
- gateway retention or a renewable manifest lease keeps the selected manifest,
  index, and objects reachable for the runtime lifetime; mutable tags and
  expiring conversion operation ids are never runtime authority;
- a local remote-backed runtime lease roots the verified index and every object
  promoted into the CAS without minting a completeness stamp, so concurrent
  local GC cannot remove the active working set;
- exhausted network, authorization, retention, or integrity failures complete
  the affected virtio-blk request with a clean I/O error and expose no partial
  guest bytes; retry, credential refresh, prefetch, and offline policy stay
  outside the virtqueue parser;
- a bounded host-side content-source worker owns HTTP, credential refresh,
  cancellation, and per-origin concurrency; the virtqueue path waits only for
  a verified object result and does not become an HTTP or authentication
  implementation;
- global rootfs-cache locks are never held across remote I/O, and local GC
  coordinates with installed objects and runtime leases rather than with the
  gateway request itself.

Static image archives remain valid for eager bulk transfer, but choosing them
in G1 cannot remove per-object storage or the authorization-bound object API.
This keeps the first product operationally simple while avoiding a protocol
rewrite when fresh-host startup eventually moves from eager pull to demand
faulting.

The first G5 lazy consumer is a read-only `spore run --image` rootfs. Build
bases, native push, bundle pack, saved-machine publication, and workflows that
require offline authority continue to require an eager-complete image or an
explicit materialization step. They never silently capture or publish a
remote-backed partial CAS.

## Pull Policy And User Experience

The explicit first slice always performs gateway resolution and installs the
requested local tag. Transparent integration follows only after the proof:

- `--pull=never` never contacts the gateway and requires a valid local ref;
- `--pull=missing` uses a valid local ref, otherwise asks the configured
  gateway before falling back to direct OCI according to explicit policy;
- `--pull=always` asks the gateway to re-resolve a mutable source tag, but an
  already selected immutable result still installs by digest;
- a digest-pinned source never changes identity under any policy.

G1 requires an explicit `--platform`; G2 derives it from the run or build target
and lets an explicit flag override only where the current command already has a
target-platform surface. The same textual gateway or local tag may have arm64
and amd64 entries, but resolution always produces exactly one platform-specific
native image. An x86_64 host requests OCI `linux/amd64`; clients never silently
select the first descriptor in a multi-platform index.

Direct OCI fallback must be explicit in gateway configuration or CLI policy.
Silent fallback would bypass source admission, audit, and upstream credential
mediation. A deployment may choose `gateway-required` or
`gateway-then-direct-public`; denied sources never fall through.

These policies govern managed remote resolution in `run`, `create`, `build`,
and the eventual `spore image pull` integration. Explicit `spore rootfs build`
remains an operator-invoked direct conversion path, while `import-oci` and
`import-tar` consume already-local bytes. The CLI is not a host egress security
boundary; deployments that must forbid direct registry access enforce that in
network policy. Help text must distinguish top-level saved-machine `spore pull`,
the new image-scoped `spore image pull`, and the lower-level rootfs commands.

The first transparent surface should be one shared rootfs resolution option
used by `run`, `create`, `build`, and libspore rather than four independent CLI
implementations. C and Go bindings follow only after the Zig contract settles.

The configured gateway origin is a separate pinned trust decision from OCI
source egress. HTTPS remains mandatory, but a deployment may explicitly allow
configured VPC or tailnet address ranges for that origin without weakening the
public-address policy used for arbitrary OCI registry redirects. The client
re-resolves and checks every gateway redirect against that configured origin
policy and drops Authorization on any disallowed cross-origin redirect.

G1 reads an opaque bearer credential from an explicitly selected mode-0600
token file or platform credential provider. Raw tokens never appear in command
arguments, environment values, events, logs, or persisted image provenance.
Production identity-provider selection remains a later deployment decision.

## Security Model

### Authority and integrity

- Remote tags, operation ids, provenance, and transport digests are discovery
  metadata, not rootfs or runtime authority.
- Platform indexes are immutable selection authority only after their digest is
  verified. A client requires one exact normalized platform match and rejects
  duplicate, absent, or cross-architecture descriptors before fetching image
  content.
- The client accepts only the existing rootfs storage kind, BLAKE3 algorithm,
  64 KiB chunk size, object namespace, device binding, index size, and logical
  coverage contract.
- The gateway verifies OCI SHA-256 descriptors during conversion. A gateway
  client does not receive OCI bytes and therefore cannot independently prove
  that the native filesystem faithfully represents the named OCI source.
- The client independently verifies canonical config, every Spore object and
  index, and the resulting native image identity before publishing a local ref.
  This proves integrity of the gateway result, while source-to-native fidelity
  trusts the approved converter and is monitored by deterministic fixture and
  spot-audit reconversion.
- Conversion signatures or attestations can identify an approved worker, but
  never replace content verification.
- Attachment relations are server-owned metadata over an immutable subject.
  Neither an attachment, its issuer, nor its policy result can replace native
  image/config/index/object verification.
- The single-object and batch endpoints authorize every digest through the
  selected immutable image manifest and rootfs index. They never expose a
  repository-independent CAS existence oracle, including to a future lazy
  runtime.

### Authentication and isolation

- Every gateway operation has an authenticated principal, repository action,
  and bounded source policy decision.
- The first slice is single-tenant and reads only allowlisted public OCI
  repositories. It still requires gateway authentication so the service is not
  an open conversion or egress proxy.
- Private upstream access requires an explicit mapping from gateway repository
  and caller to an upstream credential scope. A broad service credential must
  never make all of its upstream access visible to every gateway caller.
- Public missing-set and object responses derive only from authorized logical
  repository reachability. Physical chunk dedupe may cross repositories only
  behind that boundary, when timing, quota, and error responses cannot disclose
  another image or repository; otherwise physical storage remains tenant-
  scoped.
- Attachment upload and listing require read access to the immutable subject
  plus the specific attachment action. Missing, unrelated, and unauthorized
  subjects or artifacts use non-disclosing responses rather than exposing the
  physical artifact store.
- Authorization to a gateway repository becomes the distribution authority
  after a private image is admitted; the gateway does not revalidate the
  caller's upstream permission on every cached pull unless deployment policy
  explicitly requires it.

### Egress and conversion workers

- Source registries are selected from configured origins, never arbitrary URLs
  supplied directly to a generic fetch endpoint.
- Public-registry mode retains the current HTTPS, redirect, Authorization
  stripping, and public-address policy. Explicit private-registry origins have
  separately configured DNS/IP ranges and credentials; they do not weaken the
  global SSRF policy.
- OCI manifest, config, layer count, compressed bytes, expanded bytes, paths,
  xattrs, files, and final rootfs geometry retain current bounds.
- Conversion runs in a resource-bounded worker with private scratch and no
  hypervisor or runtime-registry authority. It uses the existing untrusted OCI
  parser and native ext4 writer rather than mounting an attacker-produced
  filesystem on the gateway host.
- Worker logs and metrics exclude bearer tokens, upstream credentials, signed
  URLs, and secret request headers.

### New parser obligations

The gateway platform and image manifests, attachment records and lists, upload
proposal, control responses, capability document, and binary batch stream are
attacker-influenced parsers. Each lands with unit rejection cases and a fuzz
target in the same change, including truncation, duplicate fields, oversized
lengths, inconsistent counts, duplicate or unexpected digests, invalid UTF-8,
digest spelling, integer overflow, trailing bytes, subject mismatch, and
partial object writes. `SECURITY.md` must add these trust boundaries before the
first networked client ships.

The current OCI readers use permissive JSON decoding, so the strict gateway
parsers are explicit G0/G1 implementation work rather than a presumed reusable
helper. The protocol should prefer the smallest shapes that still preserve exact
identity and authorization, and must not grow a general canonical-JSON library
as a side effect.

## Retention And Garbage Collection

Immutable platform indexes and mutable tags are the gateway's repository roots.
A platform index roots each selected image manifest; a manifest roots its
canonical rootfs index and its related attachments; the validated rootfs index
roots every nonzero chunk. An attachment relation roots its immutable attachment
record and artifact bytes, but an attachment never roots its subject. Conversion
and attachment operations root nothing until their immutable record is
published. In-flight uploads and conversions use expiring leases rather than
visible tags.

GC is mark-and-sweep over repository-visible immutable platform indexes and
image manifests plus active leases. Object deletion is backend-specific, but
reachability is defined by the platform, native image, and rootfs indexes.
Mutable tag replacement does not delete the prior immutable image immediately;
retention policy decides when untagged manifests become eligible.

G5 adds renewable client/runtime leases for untagged or otherwise
retention-sensitive lazy images. The gateway must not delete an image manifest,
rootfs index, or reachable object while such a lease is live. Eager clients need
no runtime lease after complete local installation.

The gateway must account logical repository bytes separately from physical
deduplicated bytes. Quotas and billing cannot be inferred from physical CAS
usage alone, especially if dedupe crosses repositories.

## Observability

Every resolve/convert/pull result records or reports:

- gateway request and operation id;
- authenticated repository and action, without credentials;
- requested source, top-level OCI index digest, and selected digest-pinned OCI
  manifest;
- platform and conversion contract;
- conversion hit, miss, single-flight wait, failure class, and worker duration;
- upstream manifest/config/layer bytes fetched and reused;
- rootfs index digest, object count, logical bytes, unique object bytes, and
  conversion phase timings;
- client manifest/index/object bytes fetched and reused;
- batch count, batch retries, validation time, cache-lock wait, install time,
  and local-ref publication time;
- gateway backend object reads, backend bytes, batch-composition CPU, response
  bytes, and data-plane egress;
- bytes read and hashed while re-verifying partially reused local CAS objects;
- end-to-end time until the installed image is usable by `spore run` or
  `spore build`.

G5 additionally reports lazy object hits, remote faults, per-digest waiters,
fault latency and bytes, local promotions, prefetch bytes, lease refreshes, and
clean I/O failures, split by platform without recording credentials or object
digests.

Structured output must distinguish upstream cache hits, gateway conversion
hits, gateway object hits, client CAS reuse, and local image-ref hits. Folding
them into one `cache_hit` bit would make performance regressions impossible to
diagnose.

## Current Progress

The first behavior-preserving extraction has landed.
`src/image.zig` now owns the canonical native image configuration, exact JSON
bytes, config digest, and indexed-image digest. Existing OCI parsing retains
its public type aliases, while local indexed-image publication delegates to
the extracted module. Golden tests freeze the complete config field order,
including `OnBuild`, and distinct arm64 and amd64 image identities. This adds
no gateway configuration, network path, cache behavior, or runtime dependency;
Spore remains fully local and direct-OCI capable.

A direct comparison with the pre-extraction source confirmed that the config
field definitions and order, null omission, domain strings, u64 little-endian
framing, digest prefix, and publication call order are unchanged. Additional
goldens pin JSON escaping, empty-versus-present config objects, and the existing
unknown-field-dropping OCI projection so later Zig or schema changes cannot
silently move native image identity.

The immutable platform-index portion of G0 is also implemented. The bounded
canonical v1 schema represents one or both required OCI platforms, freezes
arm64 variant normalization, rejects ambiguous or noncanonical input, and ships
reusable golden and malformed fixtures plus fuzz coverage. The protocol remains
data-only: it adds no gateway lookup, network path, backend mapping, or runtime
dependency.

The gateway source selector, direct registry pulls, and local OCI-layout
imports now share the protocol's arm64 normalization and ambiguity rule. All
three selection paths accept an absent or `v8` arm64 variant, require amd64 to
omit its variant, and reject multiple eligible descriptors that normalize to
the requested platform.

The bounded canonical image-manifest schema has also landed as a distinct,
data-only protocol module. Its arm64, amd64, and native fixtures exercise exact
config, index, platform, object-summary, and native-image closure verification;
the final short chunk keeps the summary contract honest for a future lazy pull.
The module has no network, registry, filesystem, CAS, or runtime dependency.

An explicit eager pull proof has now landed. `spore image pull` fetches a
repository-bound source alias, selects exactly one requested architecture,
verifies the canonical manifest/config/index closure, stages every distinct
nonzero object outside the cache lock, and publishes through the existing CAS,
completeness-stamp, image-metadata, and local-ref transaction. The resulting
ordinary local ref boots through `spore run --image ... --pull=never`; no run,
create, build, or runtime path depends on a gateway. A static fixture exporter
and loopback-only insecure flag make the complete HTTP path reproducible without
pretending to provide a gateway service.

The minimal attachment protocol has also landed as a data-only module.
Canonical records bind one supported artifact descriptor to an immutable image
manifest, while bounded deterministic subject lists bind record digests and
types without creating client-maintained tags. Verification covers the
requested subject, record bytes, type, and exact artifact bytes. Golden,
malformed, subject-binding, and fuzz coverage freeze the envelope; upload,
relation mutation, authorization, retention, and policy remain deferred to G3.

The converter-worker equivalence fixture now uses two deterministic layers,
one uncompressed and one gzip-compressed, across both target platforms on Linux
arm64 and Linux amd64 workers. It covers whiteout and overwrite behavior,
links, modes, numeric ownership, runtime config, and non-chunk-aligned content.
Each run must reproduce the committed canonical config, rootfs index, gateway
manifest, platform index, native image digest, and complete object summary. The
versioned bundle under `test/image-gateway/worker-conformance/` is the shared
fixture exchange surface; it adds no service or runtime behavior.

The transport benchmark harness has landed without adding a service or product
protocol. It records fresh direct-OCI conversions and profile logs, exports the
current verified fixture, then compares per-object GETs, a deterministic static
archive, and bounded benchmark-only missing-object batches across cold and
partially populated caches. Rows include provenance, phase timings, reuse,
connections, requests, backend reads and bytes, response bytes, retries, and
batch-composition time; all client modes use bounded disk staging and 16-way
connection reuse, while archive construction records its separate one-time
cost so the real workload remains measurable.

The five-sample two-platform evidence is recorded in
[`docs/benchmarks/image-gateway-transport-2026-07-22.md`](../benchmarks/image-gateway-transport-2026-07-22.md).
On the S3 workload, the archive was fastest and transferred less than half the
raw object payload on both architectures. The real workload compressed 4.5–4.8
GB of objects to 1.6 GB, while related-image reuse covered only 1.6% of ARM64
bytes and 6.5% of AMD64 bytes. G0 therefore selects a rebuildable immutable
archive for G1 eager bulk transfer, retains per-object authority and the
manifest-bound object API for future lazy pulls, and defers dynamic batch
framing to G2 unless production telemetry shows materially higher reuse.

The first G1 product transport now implements that archive decision for final
native images. `spore image pack` exports a complete local `spore build` or
`spore run --commit` result as one immutable SHA-256-addressed gzip/USTAR object;
`spore image unpack` requires that transport digest, the expected native image
identity, and an explicit platform,
re-verifies the canonical gateway manifest, config, rootfs index, native image
identity, and every BLAKE3 object, then publishes an ordinary local ref last.
The Buildkite acceptance pipeline builds and packs in one job, crosses the
artifact boundary, unpacks into a clean rootfs cache in a dependent job, checks
the exact native identity, and runs that image through `--pull=never`. This
closes final native-image distribution without capturing suspended machine
state, adding a gateway service framework, or distributing Dockerfile step
cache records.

The proof intentionally uses one manifest-bound GET per object, so it measures
correctness rather than the final eager transport. Before object transfer, it
rejects images above 16 GiB logical size, 65,536 distinct nonzero objects, or
4 GiB of nonzero payload. These are client resource bounds for the eager proof,
not native image-format limits. It has no authentication,
conversion admission, server authorization, missing-object optimization,
redirects, retries, or gateway provenance record.

Repository-bound authorization conformance now freezes the single-object data
plane independently of an implementation. Two principals have disjoint
repository grants over manifests that share physical object identities; only
objects reachable from the authorized repository and immutable manifest can be
read. Missing authentication returns `401`, while every authenticated missing,
denied, or unreachable case returns the same empty `404`. This keeps physical
deduplication from becoming cross-repository authority and preserves the
manifest-bound object path needed by a future lazy-pull client.

G0 also fixes repository ownership before service work begins. The service and
worker implementations belong in the public `sporevm/image-gateway` repository,
while deployment configuration and infrastructure remain in the private
`sporevm/sporevm-ops` repository. This repository retains the protocol,
canonical fixtures, client, and direct-OCI implementation so Spore continues to
work without a gateway. The versioned conformance bundle is the boundary between
the repositories; the service must consume it rather than importing SporeVM
internals.

## Delivery Strategy

### G0 — Freeze the protocol and benchmark fixture

Status: complete prerequisite. Native identity, platform-index, image-manifest,
attachment-schema, representative converter-worker equivalence, explicit
eager-client proof, authorization, cross-repository conformance, transport
evidence, the G1 archive choice, and repository ownership are frozen.

- Write the durable gateway protocol and JSON/binary schemas with exact size,
  count, digest, and version bounds.
- Freeze the negative data-plane contract: no repository-independent blob or
  object endpoint, generic existence `HEAD`, cross-repository mount, global
  missing-set request, or client-maintained attachment tag is part of v1.
- Freeze the minimal typed attachment envelope and server-owned immutable-
  subject relation semantics, with golden and malformed fixtures, while
  deferring the attachment service surface to G3. The data-only schema,
  deterministic relation list, exact subject binding, and parser fuzz coverage
  have landed; service behavior remains deferred.
- Define the immutable platform-index schema and OCI platform normalization.
  The first schema must represent both required platforms without a version
  bump or architecture-specific field names; runtime-backend naming remains a
  separate SporeVM boundary.
- Publish byte-level golden vectors for canonical image-config JSON,
  `sporevm-indexed-image-config-v1`, and `sporevm-indexed-image-v1`, generated
  from current code. Reconcile the durable format doc's canonical config field
  list, including the current `OnBuild` field, before another implementation
  exists.
- Add canonical fixtures for arm64 and amd64 OCI-converted images plus one
  native `spore build` image, including a multi-platform index, same-tag
  platform selection, malformed cases, and the concrete 64 MiB canonical-index
  bound.
  The schema fixtures, malformed corpus, closure verifier, versioned worker-
  equivalence bundle, and two-worker CI matrix have landed.
- Run at least one selected target-manifest fixture through arm64 and amd64
  converter workers and require byte-identical config, index, and image digests;
  the worker architecture must not leak into native output. The committed
  two-target minimal fixture and Linux arm64/amd64 CI jobs now enforce this
  invariant for compressed and uncompressed layers with representative
  filesystem and runtime metadata.
- Record a reproducible direct-OCI baseline for a small public image and the
  real `buildkite-sporevm` base on an empty client cache, pinned to the native
  writer and exact rootfs builder version. The two-platform small S3 baseline
  and real-workload evidence are recorded in the benchmark evidence note. The
  ARM64 real-workload conversion timing has a documented dirty-provenance
  qualification and is not exact-head acceptance evidence.
- Compare a prewarmed host cache and a simple immutable static image archive
  served from object storage with dynamic missing-object batches. If the G1
  acceptance workload does not benefit materially from partial-cache reuse,
  use the static archive in G1 and defer the binary batch parser to G2. The
  S3 and overlapping-workload evidence selects the static archive for G1;
  batch framing remains benchmark-only and deferred to G2.
- Freeze the authorization-bound single-object fetch contract and prove that a
  client can fetch any reachable chunk, cannot fetch an unrelated CAS object,
  and receives bytes identical to archive or batch transport. This is a protocol
  prerequisite even though G1 remains eager.
- Record source manifest digest, platform, conversion contract, rootfs index
  digest, object count/bytes, commands, phase logs, server-side storage requests,
  and end-to-end transfer economics. The harness schema covers these fields;
  service-side queue, conversion, and production backend evidence join in G1.
- Decide the separate gateway repository before service implementation begins.
  Service and worker code belongs in public `sporevm/image-gateway`, deployment
  remains in private `sporevm/sporevm-ops`, and the shared fixture exchange is
  pinned by the versioned conformance bundle and its exact output files.

Done means another implementation can produce or consume both platform fixtures
without reading SporeVM's internal structs, the exact identity preimages are no
longer implicit code behavior, and the benchmark identifies how much time is
conversion versus unavoidable transfer. The same textual tag selects distinct
arm64 and amd64 manifests without collision, and the benchmark makes an
explicit archive or batch transport choice for G1 from measured cold and
partially reused caches without removing the single-object interface.

### G1 — Read-only public OCI gateway

Status: active. The final-native-image archive and clean-worker artifact path
are implemented as the first independently useful G1 slice. The mediated
pull-through service work below remains proposed and is not required for native
image artifact distribution.

- Pack one complete local native image closure into the immutable compressed
  archive selected by G0, while keeping archive bytes outside native identity.
- Require the archive SHA-256, expected native image BLAKE3, and explicit
  platform on import, then verify and install through the existing CAS and
  local-ref publication transaction.
- Prove CI handoff in separate jobs: build and publish the artifact on the
  producer, download into an empty rootfs cache on the consumer, compare the
  native image identity, and run through `--pull=never` without saved state.
- Keep artifact upload/download owned by the CI or object-store transport. The
  product archive commands do not introduce credentials, repository policy, or
  a general service framework.

- Implement authenticated single-tenant conversion admission for configured
  public OCI repositories and both `linux/arm64` and `linux/amd64`.
- Resolve one upstream tag generation into selected per-platform manifests,
  single-flight each conversion key, and publish immutable gateway manifests
  plus an atomic platform index only after each included native storage value is
  complete.
- Implement bounded index fetch and the transport selected by G0. If batching
  wins, include its authorization-bound strict parser, bounded concurrency,
  and server-side storage accounting in this slice.
- Implement and conformance-test authorization-bound single-object fetch even
  when the eager client uses a static archive.
- Prove every batch and single-object request is reachable from its authorized
  immutable manifest and that no alternate endpoint or response distinguishes
  physical CAS state.
- Promote `spore image pull --gateway ... --ref local/... SOURCE` from its
  loopback/static proof to the authenticated G1 service using private
  staging, an explicit platform, and the existing local CAS publication
  transaction.
- Preserve exact image config and publish an ordinary local image consumable
  through `--pull=never` by current run, create, and build paths.
- Emit structured conversion, transfer, reuse, and install accounting.

The native-distribution slice is done when the two-worker acceptance above is
green for an exact branch head and digest or architecture substitution fails
before local-ref publication. This is the completion boundary for issue #545;
it deliberately does not claim the later mediated OCI conversion service is
implemented.

Done means the same upstream multi-platform tag resolves to the pinned arm64 and
amd64 source manifests from one upstream index generation, produces canonical
config with the matching OCI architecture, and publishes distinct native image
identities under one gateway tag. Two clients with empty independent caches pull
one platform conversion, receive canonical rootfs index and config bytes
identical to pinned direct OCI conversion, recompute and publish the same
indexed-image digest for that platform, run a command successfully, and prove a
gateway conversion hit on the second request. The same client then pulls an
overlapping image revision into its partially populated CAS: when G1 uses
batching, transferred bytes approximate the unique missing bytes and request
count is proportional to bounded batches rather than rootfs chunk count.
Median time to a usable image beats direct OCI conversion for the real workload
under the same network placement, with server storage requests and gateway
egress reported beside client request count.

The gateway and client protocol are not considered G1-complete until both
platforms pass conversion and selection conformance. An arm64-only runtime
preview may land while the x86_64 backend is in progress, but the end-to-end G1
acceptance matrix includes an arm64 host and the dedicated x86_64 KVM host once
that backend can boot images.

### G2 — Shared resolution for run, create, and build

Status: proposed follow-up.

- Add one gateway-aware rootfs resolution seam used by CLI and libspore.
- Implement explicit `gateway-required` and `gateway-then-direct-public`
  fallback policies plus current `missing|always|never` semantics.
- Let `spore run --image`, named create, and reachable external `FROM` or
  `COPY --from` inputs consume gateway results without changing downstream
  image or build execution.
- Derive gateway platform selection from the exact run/build target. Build
  planning must distinguish `BUILDPLATFORM` and `TARGETPLATFORM`; it never
  substitutes host architecture for an explicit target.
- Keep all Dockerfile planning and unsupported-feature failure before network
  fetch where current preflight guarantees it.

Done means conformance covers mutable tags, digest-pinned refs, local hits,
gateway hits, denied sources, gateway unavailability, explicit direct fallback,
concurrent local installation, and GC races. Every managed remote image
resolution honors a gateway-required policy; explicit local conversion/import
and deployment-level egress retain the boundary described above.

### G3 — Native image push and repositories

Status: proposed follow-up.

- Add immutable native upload plus atomic, platform-scoped gateway tag updates
  for images produced by `spore build` and `spore run --commit`; publishing one
  platform preserves the other platform descriptors unless the caller
  explicitly replaces the whole tag generation.
- Add proposed-manifest upload transactions: privately stage and validate the
  canonical index, derive its object closure server-side, report logical
  repository misses only, and validate all uploaded bytes before publication.
- Add repository read/write/delete actions, immutable inspection, tag listing,
  retention, and GC.
- Add typed attachment upload, listing, filtering, inspection, deletion, and
  retention over immutable gateway image-manifest subjects. The service updates
  relations atomically; clients never update a derived tag or mutable list.
- Preserve multiple provenance and policy records without selecting one or
  changing native image identity.

Done means a build host pushes a final image, a clean runtime host pulls and
runs it without OCI export/import, tag replacement is atomic, unauthorized
read/write is rejected, and concurrent push/GC cannot expose incomplete state.
A destination missing-set cannot reveal physical objects reachable only from
another repository, and concurrent attachment publication cannot lose an
existing relation or keep a deleted subject alive.

### G4 — Private OCI mediation and production hardening

Status: deferred until G1/G2 prove value.

- Add scoped upstream credentials and configured private registry origins.
- Add tenant/repository isolation, quotas, audit retention, rate limiting,
  worker isolation, high availability, and disaster recovery.
- Decide whether physical CAS dedupe may cross tenants from a measured side-
  channel and accounting analysis.
- Add conversion-attestation producers, source signature verification, and
  policy hooks through the G3 typed attachment relation without making them
  content authority.

### G5 — Measured extensions

Status: deferred.

- Add an explicit lazy-pull policy backed by a verified remote content source,
  renewable manifest leases, per-digest single-flight fetch/install, and clean
  virtio-blk I/O failure for read-only `spore run --image`. Keep local
  completeness distinct from remote-backed availability, require eager
  materialization for build/pack/push/save consumers, and measure lazy against
  eager pull before making it a default.
- Centrally prepared build bases keyed by the complete PREPARE identity.
- Static packfiles, range reads, peer selection, or OCI artifact adapters if
  measured batch composition or object-store request cost justifies them.
- Additional platforms or OCI architecture variants beyond the normalized
  linux/arm64 and linux/amd64 requirements, plus new conversion contracts.
- A separately designed signed, tenant-scoped remote Dockerfile step cache.

## Verification

### Format and parser gates

- Canonical gateway-manifest encoding and digest fixtures.
- Canonical platform-index encoding, ordering, digest, arm64/amd64 selection,
  and duplicate-platform rejection fixtures.
- Canonical typed attachment record, immutable-subject binding, deterministic
  relation listing, and malformed or duplicate descriptor fixtures.
- Cross-implementation golden tests between client and service repositories.
- Unit and fuzz coverage for every new JSON and binary parser.
- Exact canonical config bytes plus current config and native image digest
  preimage vectors.
- Exact current rootfs storage and disk-index validation, including the current
  maximum canonical index and last short-chunk geometry.
- Rejection of unsupported kinds, versions, platforms, algorithms, devices,
  chunk sizes, namespaces, bounds, and trailing data.

### Correctness gates

- Pinned native direct OCI conversion and gateway conversion produce identical
  canonical rootfs index and canonical image-config JSON bytes; both derive the
  same indexed-image digest even though direct OCI cache metadata uses a
  different local ref shape today.
- The same upstream multi-platform tag resolves arm64 and amd64 descriptors from
  one top-level OCI index generation; each canonical config has the selected
  OCI architecture, each local ref resolves only for its platform, and neither
  runtime accepts the other platform's image.
- Pull into an empty cache, partially populated cache, fully populated cache,
  and cache containing corrupt, wrong-shaped, or symlinked entries.
- Kill or crash during manifest, index, batch, install, completeness, metadata,
  and local-ref phases; no incomplete state becomes reachable.
- Concurrent pulls of the same image and overlapping images into one local
  cache.
- A GC deletion between unlocked presence probing and locked installation
  triggers one bounded re-fetch retry and never a completeness stamp over
  missing storage.
- Concurrent gateway conversion, push, tag replacement, retention, and GC.
- Direct run, named create, Dockerfile `FROM`, cross-stage/image `COPY --from`,
  pack, cache GC, and system prune after installation.
- Mutable tag movement records old and new selected digests without aliasing
  their conversion outputs or mixing arm64 and amd64 descriptors across source
  generations.
- Single-object, batch, and archive paths return identical bytes for every
  reachable object; single-object requests reject unrelated digests.
- Proposed-manifest upload staging derives the exact object closure, reports
  only authorized logical repository misses, survives interruption without
  publication, and publishes objects, index, config, manifest, and tag in order.
- Concurrent attachment publication preserves every valid immutable record;
  deletion and GC remove attachments with an unreferenced subject while an
  attachment alone never retains that subject.

### Security gates

- Repository allow/deny and non-disclosing unauthorized responses.
- Gateway-required mode never falls through to direct OCI.
- Batch reads are authorized to one readable immutable gateway manifest and
  reject digests not reachable from its selected rootfs index.
- Route and capability conformance proves there is no generic blob/object
  `HEAD`, repository-independent digest lookup, cross-repository mount, global
  missing-set query, or client-maintained attachment tag.
- Identical physical CAS state behind two authorization layouts produces the
  same public missing-set, denial, quota, and error behavior; cross-repository
  physical hits remain admin-only accounting.
- Attachment reads and writes require the subject repository and attachment
  action, reject subject mismatch, and do not disclose artifacts attached only
  to another repository.
- Configured private gateway origins do not weaken public OCI source/redirect
  address policy.
- Redirect, DNS rebinding, private-address, cross-origin Authorization, token
  realm, oversized body, decompression, and tar/path/xattr cases retain current
  protections.
- Batch truncation, duplication, reordering, injection, length overflow, and
  unexpected-object tests.
- Worker scratch, credential, quota, cancellation, and cleanup tests.
- Poisoned-conversion tombstone/reconvert and deterministic spot-audit tests.
- Security review of tenant dedupe before private multi-tenancy.
- G5 adds expired/renewed runtime lease, token refresh, remote timeout,
  unavailable object, wrong digest, concurrent fault, cancellation, and local
  GC tests. Every failed multi-descriptor read completes with I/O error and no
  partial guest payload.

### Product and performance gates

- Package the exact candidate `spore` binary and record client, service,
  converter, source, and output provenance.
- Run at least five sequential empty-client direct OCI and gateway trials under
  the same network placement, plus warm gateway and partially populated local
  CAS trials.
- Include prewarmed-host and static-archive controls before committing G1 to a
  custom batch transport.
- Report phase medians rather than wall time alone: resolve, queue, source
  fetch, conversion, manifest/index fetch, object transfer, verification,
  install, and first command. Report gateway backend requests, composition CPU,
  egress, and bytes read/hashed for locally reused chunks as separate costs.
- Use the unchanged real `buildkite-sporevm` base plus a small public image so
  the result is neither workload-specific nor synthetic-only.
- Run conversion and transfer accounting for both arm64 and amd64. Full runtime
  time-to-usable-image gates run on the arm64 host and the x86_64 KVM host as
  backend support becomes available, with platform-specific baselines rather
  than comparing unlike hosts directly.
- Require identical canonical rootfs index and config bytes, the expected
  derived indexed-image digest, and a lower median time to usable image for the
  real cold workload before G2 starts.
- Verify `spore ps` reports no leftover VMs and remove task-owned service,
  staging, cache, and benchmark state after each acceptance run.

## Resolved Decisions

- The first product is an image gateway, not a general OCI registry.
- OCI remains an input edge; native Spore image identity and CAS remain the
  output contract.
- Eager mode treats remote state only as a verified byte source and discovery
  service. A future explicit lazy mode may bind one immutable manifest and
  rootfs index as remote content-source authority under a runtime lease; mutable
  tags never become runtime authority.
- The first user-visible surface is explicit `spore image pull`; transparent
  run/build integration follows the performance proof.
- Per-chunk storage remains the server authority. G0 chooses static archive or
  authorization-bound dynamic batch transfer for G1 from cold and overlapping-
  image reuse measurements; transport layout never enters image identity, and
  the single-object interface remains available for future lazy pull.
- Network fetch happens outside the local rootfs-cache lock; installation and
  publication reuse the existing locked transaction.
- No public global blob namespace, cross-repository mount, or unrestricted
  digest-existence API exists. Push missingness is derived from a privately
  staged proposed manifest and authorized logical repository reachability;
  physical CAS dedupe remains an internal implementation detail.
- Provenance extensions, signatures, SBOMs, and policy results are multiple
  typed immutable attachments to a gateway image-manifest digest. The service
  owns their atomic relation, clients never maintain magic tags, and attachments
  do not change or retain native image identity.
- Service code and deployment live outside the SporeVM runtime repository;
  protocol, client verification, and shared fixtures remain owned here.
- The first slice is authenticated, single-tenant, public-source, and
  supports both `linux/arm64` and `linux/amd64` in protocol, conversion,
  repository, and conformance surfaces.
- Native image push comes after pull-through conversion.
- Eager complete installation ships before remote faulting, but lazy-pull
  compatibility is a core protocol requirement rather than an after-the-fact
  format extension.
- Prepared bases, private upstream credentials, and remote Dockerfile step
  cache are not first-version requirements.

## Key Learnings From Pressure-Testing

- One registry blob per 64 KiB chunk preserves dedupe but turns a large image
  into tens of thousands of requests; one static image pack reduces requests
  but loses local and cross-image transfer reuse. Bounded server-composed
  batches preserve those client properties, but move object-store request
  amplification, composition CPU, egress concentration, and CDN loss into the
  gateway. G0 measures all three rather than freezing a transport by intuition.
- A global blob existence or cross-repository mount API would turn physical
  dedupe into an authorization side channel. Every read and missing-set request
  is therefore bound to an immutable or privately proposed manifest closure;
  clients may upload a byte the service already stores physically so logical
  authorization remains unobservable.
- Adding provenance later through derived tags would create client-side
  read-modify-write races and a second use for mutable tag semantics. G0 freezes
  a typed immutable attachment envelope and server-owned relation, while G3
  implements the service only after image push exists.
- A single-platform gateway tag would force a repository and API migration as
  x86_64 lands. The first tag format is therefore an immutable platform index;
  conversion and image identities remain per-platform, while tag replacement
  is atomic across one source generation.
- An eager-only static archive would make lazy pull require a new storage and
  authorization protocol. G1 may use an archive for bulk transfer, but canonical
  per-object storage and one-object authorization stay in v1, while ordinary
  local refs still require complete installation.
- A transparent gateway fallback can silently bypass the mediation users rely
  on. Fallback is therefore an explicit deployment policy, and authorization
  denial never falls through.
- Holding the local CAS lock across network I/O would serialize unrelated runs
  and builds. The client verifies in private staging and holds the lock only for
  recheck, install, completeness, metadata, and local-ref publication; a GC race
  on a presumed-present object gets one bounded unlocked re-fetch retry.
- Canonical config bytes must travel verbatim. Re-embedding OCI config as a
  gateway-shaped JSON object would create a second canonicalizer and break
  indexed-image identity.
- The client verifies the integrity of native bytes but trusts the gateway to
  have converted the recorded OCI source faithfully. Worker provenance,
  deterministic fixtures, spot audits, and poisoned-key recovery make that
  conversion authority visible rather than pretending the client re-verifies
  OCI input it never receives.
- Distributing final images is content-verifiable; sharing Dockerfile step
  records adds semantic cache authority and needs a separate trust design.
- The gateway is justified only if the end-to-end cold path improves on the
  real workload. G1 therefore ends at a measured decision gate rather than
  committing the runtime and build paths to a service before the win is proven.

## Open Questions

These do not block G0 or the read-only G1 proof:

- Which deployment identity provider and logical image-repository naming scheme
  should production use? The service code repository is fixed as
  `sporevm/image-gateway`; G1 needs only an authenticated single-tenant image
  namespace.
- Should a production gateway expose an OCI artifact adapter for generic
  registry storage? Revisit after G1 records object count, batch composition,
  storage requests, and cross-image reuse. Any adapter remains backend-private:
  it must preserve the server-owned atomic attachment relation and cannot expose
  referrer fallback tags, global blob probes, or mount semantics to clients.
- Is central PREPARE reuse worthwhile once OCI conversion is removed from the
  cold path? Measure its remaining phase cost before G5.
- What side-channel and accounting policy permits cross-tenant physical chunk
  dedupe? Keep storage tenant-scoped until G4 answers it.
