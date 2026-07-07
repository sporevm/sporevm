# Spore Format

**Status:** manifest format v0 implemented (`src/spore.zig`), single-vCPU,
same-host HVF and KVM producers/consumers. Manifest format v1 has data structs,
validators, KVM portable capture/restore, and HVF same-backend capture/restore
for multi-vCPU state. Bundle production, pull, and local materialization
preserve manifest v1.

Format v0 is still the current SporeVM 1.x manifest and artifact contract.
Do not rename version or kind strings to v1 for release-label symmetry; use a
format v1 only for an incompatible on-disk, bundle, or guest-visible contract
change with a migration decision.

A spore is sealed, content-addressed VM state. The format, not the
implementation, is the product: two SporeVM builds on different hypervisors
interoperate through this document.

For the backend mapping rules, state classes, and current restore-direction
matrix, see [Spore State Portability Contract](state-portability.md).

## Layout

A spore is a directory:

```text
<spore>/
├── manifest.json
├── chunks/<blake3-hex>     # content-addressed data chunks
├── ram.backing             # optional local same-host RAM acceleration file
├── ram.backing.proof       # optional local-only provenance proof
├── disklayers/blake3/<hex>.json
│                           # optional sealed writable disk layer indexes
└── diskobjects/blake3/<hex>.cluster
│                           # optional content-addressed disk clusters
```

Spores saved from `spore run --image ... --save` may also require rootfs
storage from the local rootfs cache. The manifest records an immutable ext4
artifact digest, size, device binding, and provenance. Image-created spores also
record `rootfs.storage` for the default chunked rootfs CAS path when available.
Rootfs bytes are not stored inside the spore directory today; `spore attach`
opens and verifies the manifest-selected exact artifact or chunked storage
before boot.

A local single-spore bundle is the first distribution form:

```text
<bundle>/
├── manifest.json           # portable manifest; local RAM backing stripped
├── chunkpack.index.json    # blake3 chunk id -> pack/offset/length/sha256
├── chunkpacks/000000.pack  # uncompressed logical chunks concatenated
├── rootfs/blake3/<hex>.ext4
                            # optional exact immutable rootfs artifact
├── disklayers/blake3/<hex>.json
│                           # optional writable disk layer indexes
└── diskobjects/blake3/<hex>.cluster
                            # optional writable disk cluster objects
```

An indexed distribution bundle can carry a parent manifest and many child
manifests without duplicating shared memory chunks:

```text
<bundle>/
├── bundle.json
├── manifests/
│   ├── parent.json
│   └── children/000042.json
├── chunkpack.index.json
├── chunkpacks/000000.pack
├── rootfs.index.json       # optional rootfs digest -> artifact policy
├── rootfs/blake3/<hex>.ext4
├── rootfs/blake3/indexes/<hex>.json
├── rootfs/blake3/objects/<hex>.chunk
├── disklayers/blake3/<hex>.json
└── diskobjects/blake3/<hex>.cluster
```

Bundles are an implementation format for distribution, not a new machine-state
contract. The BLAKE3 ids in the selected manifest remain the restore-time trust root;
the SHA256 values in the chunkpack index make each packed segment compatible
with blob-store and later OCI-style descriptor verification. `spore pack` and
`spore unpack` also report a `bundle_digest`, a SHA256 digest over the exact
bundle bytes that affect materialization, including bundle metadata, manifests,
chunkpack metadata, pack blobs, rootfs metadata, included rootfs artifacts,
chunked rootfs indexes and objects, disk layer indexes, and disk objects. It is
not a replacement for per-chunk, per-rootfs, or per-disk-object verification.

If `manifest.json` records an immutable rootfs artifact, `spore pack` includes
the exact ext4 bytes at `rootfs/blake3/<hex>.ext4` after verifying the source
digest-cache entry by BLAKE3 and size. `spore unpack` requires that bundled
artifact, verifies it against the manifest, then installs it into the local
rootfs digest cache before writing the unpacked manifest. Indexed bundles record
that artifact in `rootfs.index.json` with an explicit `exact-bytes` policy by
default. `spore pack --children ... --rootfs=metadata-only` records the same
digest and size with `metadata-only` policy and omits the ext4 file; materialized
unpack and pull accept that policy only with `--allow-metadata-only-rootfs` and
a trusted shape-compatible hit in the selected rootfs digest cache.

If `manifest.json` records `rootfs.storage.kind:
"chunked-ext4-rootfs-v0"`, indexed bundles carry the exact
`rootfs-block-index-v0` bytes named by `rootfs.storage.index_digest` under
`rootfs/blake3/indexes/<hex>.json`, plus each referenced nonzero rootfs chunk
object under `rootfs/blake3/objects/<hex>.chunk`. Unpack and pull verify the
index against the manifest storage descriptor and verify every chunk by BLAKE3
before installing them into the destination rootfs CAS cache. They do not require
the monolithic ext4 digest-cache artifact on the destination for a chunked
rootfs child.

If the selected manifest records a writable disk chain, `spore pack` includes
the referenced `disk-layer-v0` indexes and BLAKE3-addressed disk cluster objects
once per bundle. `spore unpack` and `spore pull` copy those verified files into
the materialized spore before writing the manifest, failing closed on missing or
digest-mismatched layer/object bytes.

`spore pull file:///path/to/bundle --child 42 --out child.spore` is the first
pull materialization policy. It accepts local indexed bundles, canonicalizes the
child id to the six-digit child manifest id, verifies the selected chunks through
the bundle index, and writes a normal spore directory. When
`SPOREVM_BUNDLE_CACHE_DIR` is set, or the platform cache root is available, pull
installs verified memory chunks into a node-local BLAKE3 chunk cache and hard
links them into the output spore where the filesystem allows it.

`spore push /path/to/bundle s3://bucket/prefix/` publishes an indexed bundle to
S3 by uploading only the canonical files named by the validated bundle metadata.
`spore pull s3://bucket/prefix@sha256:<bundle_digest> --child 42 --out
child.spore` downloads that exact object set into the node-local bundle cache,
checks the canonical `bundle_digest`, then uses the same chunk and rootfs
verification path as local pull, including writable disk layer/object
verification when present. Bare S3 URLs are rejected for pull because the remote
URL is not restore authority.

`spore pull http://peer:20000/spore.bundle@sha256:<bundle_digest> --child 42
--out child.spore` uses the same verified materialization path for a static
HTTP(S) peer source. The peer URL is only a byte source: it must be digest
pinned, redirects and mutable URL components are rejected, and corrupt peer
bytes fail before the local cache is marked complete. Pull results report cache
accounting for the materialization path: `remote.origin_bytes_read` for
object-store sources, `remote.peer_bytes_read` for HTTP(S) peer sources,
`remote.cache_hit`, `materialization.cache.bytes_fetched`,
`materialization.cache.bytes_reused`, and rootfs cache hit/fetch/reuse counters
under `rootfs.cache`.

## Manifest Format v0

`manifest.json` fields (see `src/spore.zig` for the authoritative shapes):

- `version`: format version, currently 0. Consumers reject unknown versions.
- `annotations`: optional opaque string map for namespaced embedder metadata,
  such as `dev.buildkite.cleanroom.policy_hash`. Keys and values are UTF-8
  strings, values are not interpreted by SporeVM, and the serialized annotation
  object is capped at 64 KiB. Restore ignores annotations it does not know.
  `libspore.inspectSpore`, `spore_inspect_spore_json`, and the Go
  `InspectSpore` binding return these key/value pairs from local `.spore`
  artifacts after the same manifest validation, so embedders can recover
  opaque metadata without sidecar files.
- `platform`: contract the restoring host must satisfy exactly — `arch`
  (aarch64), `cpu_profile`, `device_model_version`, `ram_base`, `ram_size`,
  `gic_dist_base`, `gic_redist_base`, and `counter_frequency_hz`. Restore
  fails closed on any mismatch. CPU profile `sporevm-aarch64-v0` is the
  current Apple-M/Graviton common denominator; KVM enforces it by masking RNDR
  before guest boot. Device model version 4 includes the fixed virtio-mmio
  range plus the generation MMIO device at `0x0c001000`, size `0x1000`, SPI 24
  / INTID 56. Fresh managed auto-memory runs may attach a transient grow-only
  virtio-mem device, but current capture/resume paths disable that transient
  device and do not serialize virtio-mem state into manifest v0.
- `machine`: normalized architectural state for one vCPU — `gprs` (x0–x30),
  `pc`, `cpsr`, `fpcr`, `fpsr`, `simd` (32 Q registers as u64 pairs),
  `sys_regs` (EL1 context registers by architectural name), `icc_regs`
  (GICv3 CPU-interface registers by name), and `vtimer` as the guest's
  virtual counter value plus `CNTV_CTL`/`CNTV_CVAL`, all in the platform's
  `counter_frequency_hz` tick domain. Restore re-anchors the counter so guest
  time continues from the snapshot only when the target backend exposes the
  same architected counter frequency.
- `machine.gic`: interrupt-controller state. `kind: "gicv3"` carries a
  normalized single-vCPU GICv3 subset: distributor and redistributor register
  values by architectural MMIO offset plus sampled PPI/SPI line levels. KVM
  currently emits and consumes this portable shape. `kind: "backend_private"`
  is a tagged fail-closed escape hatch for temporary same-backend restore;
  HVF currently stores `backend: "hvf"`, `format: "hv_gic_state_v0"`, and a
  base64 `hv_gic` blob until its GICv3 mapping lands.
- `devices`: ordered virtio-mmio transport states (device id, status,
  feature negotiation registers, interrupt status, and per-queue size/ready/
  ring addresses/indices). Device order is part of the board contract.
- `generation`: non-virtio generation MMIO device state — `generation`
  counter, `interrupt_status`, and `params_b64` (base64-encoded
  resume-parameter bytes with trailing zeroes elided). `spore fork` increments
  the counter per child, sets `interrupt_status` to
  `irq_generation_changed`, and writes a JSON resume-parameter payload with
  stable child identity fields: `schema_version`, `parent_generation`,
  `generation`, `fork_index`, `fork_count`, `parallel_index`,
  `parallel_count`, `fork_batch_id`, `vm_id`, `hostname`, `mac_seed`, and
  `mac_address`. `fork_index` and `fork_count` are batch-local fork metadata.
  In the first local fan-out contract they are equal to `parallel_index` and
  `parallel_count`; distributed offset/range partitioning is deferred. Backend
  restore refreshes the params page at actual resume time with volatile
  `resume_time_unix_ns` and `resume_entropy_seed` values before reasserting the
  generation interrupt.
- `sessions`: optional low-level process/session handles captured with the VM.
  A handle is generic: `id`, `kind: "process"`, and stream capabilities for
  `stdin`, `stdout`, `stderr`, and `terminal`. `spore run --from` uses the
  `default` handle when present, or the sole recorded handle for captures of a
  resumed command that was started under a generated `run-*` id. The handle
  records guest-side capability only. Host stdin, PTY ownership, terminal mode,
  and the currently attached client are never part of the spore. Producers must
  write at most 16 handles; ids are 1-63 ASCII alphanumeric, dash, underscore,
  or dot characters.
- `memory`: `chunk_size` plus one entry per chunk — a blake3-hex chunk
  reference, or null for an all-zero chunk. `backing` is optional local
  acceleration metadata for same-host KVM/HVF fork/fan-out: `kind:
  "map-private-file-v0"`, `path: "ram.backing"`, and `size`. Chunks
  remain the portable verified source of truth; unsupported backends and
  imported/cold spores materialize from chunks instead. Product restore paths
  (`spore attach` and `spore run --from`) may automatically map `ram.backing`
  when the manifest vCPU count is supported and the local `ram.backing.proof`
  validates against the manifest memory fingerprint, backing metadata, opened
  file identity, and host-local runtime key. A missing, corrupt, foreign-key,
  mismatched proof, or unsupported topology falls back to chunks.
  The proof is local provenance metadata; it is not a portable trust root and
  does not prove every RAM byte still matches the manifest's chunk refs. KVM and
  HVF map a validated fd
  `MAP_PRIVATE` to share clean parent pages across fork children while child
  writes fault into private CoW pages.
- `rootfs`: optional immutable rootfs artifact required by a captured
  read-only virtio-blk root device. `kind` is
  `immutable-ext4-rootfs-v0`, `mode` is `read-only`, `device` binds the
  artifact to the rootfs virtio-mmio slot, `artifact` records a
  `blake3:<hex>` digest, size, and `ext4` format, and `source` records OCI
  provenance. The digest and size are restore authority for the fd-backed
  path; OCI metadata is not. Image-created manifests normally also include
  `rootfs.storage` with `kind: "chunked-ext4-rootfs-v0"`, the same rootfs
  device binding, logical size, chunk size, `hash_algorithm: "blake3"`,
  `index_digest`, `base_identity`, and `object_namespace: "rootfs/blake3"`.
  For this first chunked storage kind, `base_identity` must equal
  `index_digest`, and the digest is the BLAKE3 identity of the canonical
  rootfs block index bytes. The index itself records index version
  `rootfs-block-index-v0`, logical size, chunk size, hash algorithm, object
  namespace, sorted non-zero chunk entries, and sorted explicit zero chunks;
  it does not repeat `base_identity` because that would make the index
  self-referential.
- `disk`: optional sealed writable root disk state for rootfs-backed captures.
  `kind` is `cow-block-v0`, `device` binds the disk to the same virtio-mmio
  rootfs slot, `size` is the full disk size, `base` is the immutable rootfs
  base identity, and `layers` is an ordered list of `blake3:<hex>` layer index
  references. For fd-backed rootfs this base identity is the full ext4 artifact
  digest; for chunked rootfs it is the manifest-bound rootfs storage
  `base_identity`. Reads replay newest layer to oldest layer over the
  immutable base.
  Each `disk-layer-v0` index records `cluster_size`, `disk_size`, explicit
  nonzero extents as `logical_cluster` plus cluster digest, and sorted explicit
  `zero_clusters`.
- `network`: optional requested network capability and policy. `kind` is
  `spore-net-v0`; `allow_cidrs` and `allow_hosts` record the legacy CLI egress
  allow policy, while `allow_host_ports` records exact DNS-learned host plus
  port rules and `bound_services` records restore-time guest service
  requirements by name, guest host, and guest port. The manifest does not carry
  live gateway state, TCP flows, DNS response caches, host socket paths,
  host port forwards, credential material, or helper process state. Resume and
  `spore run --from` must attach a fresh gateway that satisfies the recorded
  `requirements` and policy or fail closed. `libspore.inspectSpore`,
  `spore_inspect_spore_json`, and the Go `InspectSpore` binding expose the
  network kind, requirements, and bound-service requirements so callers can
  preflight restore-time bindings without parsing `manifest.json` directly.

## Manifest Format v1

Manifest v1 is the incompatible multi-vCPU machine-state shape. Existing v0
loaders reject it through the normal unknown-version path. The KVM runtime uses
v1 with portable `gicv3_multi` state for multi-vCPU capture and restore. The
HVF runtime uses v1 with a tagged same-HVF `backend_private` GIC blob. Bundle
commands preserve v1 manifests through production, pull, and local
materialization.

V1 keeps the v0 memory, device, generation, rootfs, disk, network, and
annotation contracts. The platform object adds:

- `vcpu_count`: bounded by the shared SporeVM topology cap.
- `gic_redist_stride`: the redistributor frame stride used to validate the
  exposed GIC layout.

The v1 `machine` object has `schema_version: 1`, `vcpus`, and `gic`.

Each `machine.vcpus[]` entry records one normalized aarch64 vCPU state:
`index`, `mpidr`, `gprs`, `pc`, `cpsr`, `fpcr`, `fpsr`, `simd`, `sys_regs`,
`icc_regs`, and `vtimer`. The validator requires stable array order
(`index == array position`), unique indexes, unique MPIDRs, and the normalized
MPIDR mapping from `src/topology.zig`.

V1 portable GIC state uses `machine.gic.kind: "gicv3_multi"`. It carries global
distributor registers, per-vCPU redistributor register arrays keyed by MPIDR,
and line levels where PPIs include an owning MPIDR and SPIs do not. Validation
rejects unknown register offsets, duplicate redistributors, duplicate line
records, PPIs without a known owner, and SPIs with an owner. HVF same-backend
v1 captures instead use `machine.gic.kind: "backend_private"` with
`backend: "hvf"` and `format: "hv_gic_state_v0"`; other backends must reject
that blob before mutating VM state.

## Not Yet Captured By Manifest v0

- General block-device state is still incomplete. The current writable disk
  contract is one rootfs-bound COW chain over a verified immutable ext4 rootfs
  artifact.
- Access traces: the KVM and HVF lazy-restore harnesses can write local
  first-touch traces for measurement, but manifest v0 does not persist access
  traces or prefetch hints.
- Multi-vCPU machine state in manifest v0. Manifest v1 carries this state for
  KVM capture/restore and same-HVF capture/restore.
- Kernel identity in the platform contract (pinned-build enforcement).
- Durable disk/device identity fixup beyond the current diskless helper. The
  product initrd consumes generation params for hostname, mixes
  `resume_entropy_seed` into the kernel RNG, and applies host-provided
  start/resume time to the guest clock, but machine-id, MAC, and other
  disk-backed workload fixups are not final.
- Cross-frequency architected timer restore: manifest v0 records and enforces
  the counter frequency, but cannot translate a running Linux guest between
  different `CNTFRQ_EL0` domains.
- Live network flows and host port forwards: manifest v0 persists requested
  network capability and policy only. Active TCP flows, learned DNS answers, and
  host loopback listeners are dropped across capture, resume, and fork.
- Transient virtio-mem state: the first grow-only auto-memory prototype is a
  fresh managed-run optimization. Manifest v0 records the fixed RAM image that
  capture/resume can restore, not virtio-mem plug state, unplug state, or guest
  hotplug policy.

## Invariants that hold regardless of version

- Chunk ids are BLAKE3-256 of chunk contents (`src/chunk.zig`); every chunk
  is verified against its id before use, from any source.
- Chunkpack bundles are portable only after local RAM backing metadata has been
  stripped. `spore unpack` reconstitutes normal `chunks/<blake3>` files and
  fails closed when a pack segment's SHA256 or logical BLAKE3 id mismatches.
- Indexed bundles validate `bundle.json` child ids and relative manifest paths
  before selecting a parent or child manifest. `spore unpack --child 000042`
  writes a normal spore directory for the selected child.
- Local `spore pull file://... --child 42` and remote digest-pinned
  `s3://...@sha256:<bundle>` / `http(s)://...@sha256:<bundle>` pulls use the
  same manifest authority but read chunks through a verified content-source
  boundary and fail closed on unsupported URI schemes, non-canonical bundle
  metadata, corrupt chunkpacks, corrupt remote bytes, or corrupt node-local
  chunk cache entries.
- Rootfs-backed bundles include exact immutable rootfs bytes by default for
  fd-backed rootfs manifests. For manifest-attached chunked rootfs storage, they
  include the descriptor-bound rootfs block index and BLAKE3 chunk objects.
  Bundle unpack refuses missing, symlinked, or digest-mismatched rootfs artifacts
  and rootfs CAS files before writing a resumable spore.
- Rootfs-backed bundles include referenced writable disk layer indexes and disk
  objects when present. Bundle materialization refuses corrupt or missing disk
  layer/object bytes before writing a resumable spore manifest.
- Immutable rootfs artifacts and chunked rootfs storage are portable by digest,
  not by local path. For fd-backed manifests, resume opens the digest-addressed
  rootfs cache entry read-only, verifies the same fd by BLAKE3 and size, and
  only then attaches it to the VM.
- Manifest-bound chunked rootfs storage descriptors select the rootfs block
  source for product resume. The runtime opens the exact local
  `rootfs-block-index-v0` named by `rootfs.storage.index_digest`, validates the
  index against that descriptor, and serves only BLAKE3-verified local chunk
  objects. Missing or corrupt index/chunk bytes fail before guest use. The
  fd-backed path must not silently ignore `rootfs.storage` and treat the
  monolithic artifact as equivalent authority.
- Local RAM backing files and `ram.backing.proof` are same-host acceleration
  hints, not portable trust roots. Product restore paths treat a valid proof as
  local provenance for opening a backing fd; invalid or absent proof uses the
  chunk manifest path. Bundles and pulls remain chunk-authoritative, and proof
  files must not be treated as distribution authority.
- Writable disk layer indexes and disk cluster objects are portable by BLAKE3,
  not by local active-head paths. Resume verifies every selected layer index and
  disk object before attaching the layered COW backend.
- Machine state is normalized architectural aarch64 state. Raw KVM structures
  never appear in the format; the only documented temporary exception is the
  explicitly tagged HVF `backend_private` GIC blob, which other backends must
  reject.
- Manifests carry a format version; consumers fail closed on versions or
  platform contracts they cannot satisfy.
- A future format-version bump needs an explicit compatibility and migration
  decision.
