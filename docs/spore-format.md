# Spore Format

**Status:** manifest format v2 is the current single-vCPU contract
(`src/spore.zig`) for same-host HVF and KVM producers/consumers. Manifest
format v3 is the current multi-vCPU contract with KVM portable
capture/restore and HVF same-backend capture/restore. The v2/v3 flag-day
break moves rootfs and writable disk identity to chunk indexes; manifest v0
and v1 are intentionally rejected as too old and must be re-created.

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
└── cas/rootfs/blake3/
    ├── indexes/<hex>.json  # optional writable disk/rootfs chunk indexes
    └── objects/<hex>.chunk # optional content-addressed disk/rootfs chunks
```

Spores saved from `spore run --image ... --save` may also require rootfs
storage from the local rootfs cache. The manifest records an immutable ext4
artifact identity, size, device binding, and provenance. For image-created
spores, that identity is the rootfs storage index digest and the manifest also
records `rootfs.storage` for the default chunked rootfs CAS path.
Rootfs bytes are not stored inside the spore directory today; `spore attach`
opens and verifies the manifest-selected exact artifact or chunked storage
before boot.

`spore build` uses local build step records under the rootfs cache at
`build/steps/<step_key>.json`. These records are host-local cache metadata, not
portable spore format. A `sporevm-build-step-v1` record binds
`builder_version`, `platform`, `step_key`, `parent_index_digest`,
`child_index_digest`, `instruction_kind`, canonical Dockerfile instruction text,
`input_digest`, `env_digest`, `workdir`, and the child's `rootfs_storage`
descriptor. A cache hit is valid only when the recomputed key matches the
record, the descriptor passes the normal chunked-rootfs storage validation,
`base_identity` and `index_digest` both equal `child_index_digest`, and the
selected rootfs CAS completeness stamp is present. Full build image identity is
the final step's `index_digest`, published through the same local image-ref
metadata path used by `spore rootfs import-tar`.

A local single-spore bundle is the first distribution form:

```text
<bundle>/
├── manifest.json           # portable manifest; local RAM backing stripped
├── chunkpack.index.json    # blake3 chunk id -> pack/offset/length/sha256
├── chunkpacks/000000.pack  # uncompressed logical chunks concatenated
├── rootfs/blake3/<hex>.ext4
                            # optional exact immutable rootfs artifact
├── rootfs/blake3/indexes/<hex>.json
└── rootfs/blake3/objects/<hex>.chunk
                            # optional writable disk/rootfs chunk CAS
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
├── rootfs.index.json       # optional rootfs identity -> artifact policy
├── rootfs/blake3/<hex>.ext4
├── rootfs/blake3/indexes/<hex>.json
└── rootfs/blake3/objects/<hex>.chunk
```

Bundles are an implementation format for distribution, not a new machine-state
contract. The BLAKE3 ids in the selected manifest remain the restore-time trust root;
the SHA256 values in the chunkpack index make each packed segment compatible
with blob-store and later OCI-style descriptor verification. `spore pack` and
`spore unpack` also report a `bundle_digest`, a SHA256 digest over the exact
bundle bytes that affect materialization, including bundle metadata, manifests,
chunkpack metadata, pack blobs, rootfs metadata, included rootfs artifacts,
chunked rootfs/disk indexes and objects. It is
not a replacement for per-chunk, per-rootfs, or per-disk-object verification.

If `manifest.json` records an immutable rootfs artifact, `spore pack` includes
the exact ext4 bytes at `rootfs/blake3/<hex>.ext4` from a trusted local
digest-cache entry, then verifies the bundled copy by BLAKE3 and size.
`spore unpack` requires that bundled artifact, verifies it against the manifest,
then installs it into the local rootfs materialization cache before writing the unpacked
manifest. Indexed bundles record that artifact in `rootfs.index.json` with an
explicit `exact-bytes` policy by default. `spore pack --children ...
--rootfs=metadata-only` records the same digest and size with `metadata-only`
policy and omits the ext4 file; materialized unpack and pull accept that policy
only with `--allow-metadata-only-rootfs` and a trusted shape-compatible hit in
the selected rootfs materialization cache.

If `manifest.json` records `rootfs.storage.kind:
"chunked-ext4-rootfs-v0"`, indexed bundles carry the exact
`spore-disk-index-v1` bytes named by `rootfs.storage.index_digest` under
`rootfs/blake3/indexes/<hex>.json`, plus each referenced nonzero rootfs chunk
object under `rootfs/blake3/objects/<hex>.chunk`. Unpack and pull verify the
index against the manifest storage descriptor and verify every chunk by BLAKE3
before installing them into the destination rootfs CAS cache. They do not require
the monolithic ext4 digest-cache artifact on the destination for a chunked
rootfs child.

If the selected manifest records a writable disk index, `spore pack` includes
the exact `spore-disk-index-v1` bytes named by `disk.base` under
`rootfs/blake3/indexes/<hex>.json`, plus each referenced nonzero disk chunk
object under `rootfs/blake3/objects/<hex>.chunk`. `spore unpack` and
`spore pull` copy those verified files into the materialized spore before
writing the manifest, failing closed on missing or digest-mismatched
index/object bytes.

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
verification path as local pull, including writable disk index/object
verification when present. Bare S3 URLs are rejected for pull because the remote
URL is not restore authority.

`spore pull http://peer:20000/spore.bundle@sha256:<bundle_digest> --child 42
--out child.spore` uses the same verified materialization path for a static
HTTP(S) peer source. The peer URL is only a byte source: it must be digest
pinned, its host must resolve only to public IP addresses, redirects and mutable
URL components are rejected, and corrupt peer bytes fail before the local cache
is marked complete. Pull results report cache accounting for the materialization
path: `remote.origin_bytes_read` for
object-store sources, `remote.peer_bytes_read` for HTTP(S) peer sources,
`remote.cache_hit`, `materialization.cache.bytes_fetched`,
`materialization.cache.bytes_reused`, and rootfs cache hit/fetch/reuse counters
under `rootfs.cache`.

## Manifest Format v2

`manifest.json` fields (see `src/spore.zig` for the authoritative shapes):

- `version`: format version, currently 2 for this single-vCPU shape.
  Consumers reject unknown versions and reject v0/v1 with a format-too-old
  error.
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
  device and do not serialize virtio-mem state into manifest v2.
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
- `memory`: sparse memory index using the same shape as disk indexes:
  `kind: "spore-disk-index-v1"`, `logical_size`, `chunk_size`,
  `hash_algorithm: "blake3"`, `object_namespace: "memory/blake3"`,
  sorted nonzero `chunks` entries (`logical_chunk`, `digest`) and sorted
  `zero_chunks`. RAM keeps the 2MiB memory chunk size; disk indexes use
  64KiB chunks. Memory chunk digests are `blake3:<hex>` references to
  portable `chunks/<hex>` files, and validation requires every logical chunk to
  be covered exactly once by either list. `backing` is optional local
  acceleration metadata for same-host KVM/HVF fork/fan-out: `kind:
  "map-private-file-v0"`, `path: "ram.backing"`, and `size`. Chunks remain the
  portable verified source of truth; unsupported backends and imported/cold
  spores materialize from chunks instead. Product restore paths (`spore attach`
  and `spore run --from`) may automatically map `ram.backing` when the manifest
  vCPU count is supported and the local `ram.backing.proof` validates against
  the canonical memory index identity, backing metadata, opened file identity,
  and host-local runtime key. A missing, corrupt, foreign-key, mismatched proof,
  or unsupported topology falls back to chunks. The proof is local provenance
  metadata; it is not a portable trust root and does not prove every RAM byte
  still matches the manifest's chunk refs. KVM and HVF map a validated fd
  `MAP_PRIVATE` to share clean parent pages across fork children while child
  writes fault into private CoW pages.
- `rootfs`: optional immutable rootfs artifact required by a captured
  read-only virtio-blk root device. `kind` is
  `immutable-ext4-rootfs-v0`, `mode` is `read-only`, `device` binds the
  artifact to the rootfs virtio-mmio slot, `artifact` records a
  `blake3:<hex>` digest, size, and `ext4` format, and `source` records OCI
  provenance. For manifests with `rootfs.storage`, the artifact digest is the
  storage index identity; without storage, the digest and size are restore
  authority for the exact fd-backed path. Image-created manifests normally also include
  `rootfs.storage` with `kind: "chunked-ext4-rootfs-v0"`, the same rootfs
  device binding, logical size, chunk size, `hash_algorithm: "blake3"`,
  `index_digest`, `base_identity`, and `object_namespace: "rootfs/blake3"`.
  For this first chunked storage kind, `base_identity` and
  `rootfs.artifact.digest` must equal `index_digest`, and the digest is the
  BLAKE3 identity of the canonical disk index bytes. The index itself records index version
  `spore-disk-index-v1`, logical size, chunk size, hash algorithm, object
  namespace, sorted non-zero chunk entries, and sorted explicit zero chunks;
  it does not repeat `base_identity` because that would make the index
  self-referential.
- `disk`: optional sealed writable root disk state for rootfs-backed captures.
  Saves use `kind: "chunk-index-disk-v0"`; `device` binds the disk to the
  same virtio-mmio rootfs slot, `size` is the full disk size, and `base` is the
  BLAKE3 digest of a `spore-disk-index-v1` index in the rootfs CAS namespace.
  `chunk_size`, `hash_algorithm`, and `object_namespace` mirror the index
  descriptor and must be `64KiB`, `blake3`, and `rootfs/blake3` for the current
  disk backend. The index records sorted non-zero chunk entries plus explicit
  zero chunks and is restore authority for the writable disk bytes.
  `cow-block-v0` manifests are old-format artifacts and are rejected with a
  format-too-old error.
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

## Manifest Format v3

Manifest v3 is the incompatible multi-vCPU machine-state shape. Existing v2
loaders reject it through the normal unknown-version path. The KVM runtime uses
v3 with portable `gicv3_multi` state for multi-vCPU capture and restore. The
HVF runtime uses v3 with a tagged same-HVF `backend_private` GIC blob. Bundle
commands preserve v3 manifests through production, pull, and local
materialization.

V3 keeps the v2 memory, device, generation, rootfs, disk, network, and
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

V3 portable GIC state uses `machine.gic.kind: "gicv3_multi"`. It carries global
distributor registers, per-vCPU redistributor register arrays keyed by MPIDR,
and line levels where PPIs include an owning MPIDR and SPIs do not. Validation
rejects unknown register offsets, duplicate redistributors, duplicate line
records, PPIs without a known owner, and SPIs with an owner. HVF same-backend
v3 captures instead use `machine.gic.kind: "backend_private"` with `backend:
"hvf"` and `format: "hv_gic_state_v0"`; other backends must reject that blob
before mutating VM state.

## Not Yet Captured By Manifest v2

- General block-device state is still incomplete. The current writable disk
  contract is one rootfs-bound chunk index over verified rootfs CAS objects.
- Access traces: the KVM and HVF lazy-restore harnesses can write local
  first-touch traces for measurement, but manifest v2 does not persist access
  traces or prefetch hints.
- Multi-vCPU machine state in manifest v2. Manifest v3 carries this state for
  KVM capture/restore and same-HVF capture/restore.
- Kernel identity in the platform contract (pinned-build enforcement).
- Durable disk/device identity fixup beyond the current diskless helper. The
  product initrd consumes generation params for hostname, mixes
  `resume_entropy_seed` into the kernel RNG, and applies host-provided
  start/resume time to the guest clock, but machine-id, MAC, and other
  disk-backed workload fixups are not final.
- Cross-frequency architected timer restore: manifest v2 records and enforces
  the counter frequency, but cannot translate a running Linux guest between
  different `CNTFRQ_EL0` domains.
- Live network flows and host port forwards: manifest v2 persists requested
  network capability and policy only. Active TCP flows, learned DNS answers, and
  host loopback listeners are dropped across capture, resume, and fork.
- Transient virtio-mem state: the first grow-only auto-memory prototype is a
  fresh managed-run optimization. Manifest v2 records the fixed RAM image that
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
  include the descriptor-bound rootfs index and BLAKE3 chunk objects.
  Bundle unpack refuses missing, symlinked, or digest-mismatched rootfs artifacts
  and rootfs CAS files before writing a resumable spore.
- Rootfs-backed bundles include referenced writable disk indexes and disk chunk
  objects when present. Bundle materialization refuses corrupt or missing disk
  index/object bytes before writing a resumable spore manifest.
- Immutable rootfs artifacts and chunked rootfs storage are portable by digest,
  not by local path. For fd-backed manifests, resume opens the digest-addressed
  rootfs cache entry read-only, verifies the same fd by BLAKE3 and size, and
  only then attaches it to the VM. For chunked manifests, the flat ext4 file is
  a materialization cache keyed by the storage index digest.
- Manifest-bound chunked rootfs storage descriptors are the authority for
  bundle/pull CAS installation and for rebuilding a missing flat rootfs cache
  entry. Rebuild opens the exact local `spore-disk-index-v1` named by
  `rootfs.storage.index_digest`, validates the index against that descriptor,
  reads only BLAKE3-verified local chunk objects, then publishes the assembled
  flat cache entry under the same index identity.
- Local RAM backing files and `ram.backing.proof` are same-host acceleration
  hints, not portable trust roots. Product restore paths treat a valid proof as
  local provenance for opening a backing fd; invalid or absent proof uses the
  chunk manifest path. Bundles and pulls remain chunk-authoritative, and proof
  files must not be treated as distribution authority.
- Writable disk indexes and disk chunk objects are portable by BLAKE3, not by
  local active-head paths. Resume validates the selected disk index and every
  referenced object before materializing the writable disk for virtio-blk.
- Machine state is normalized architectural aarch64 state. Raw KVM structures
  never appear in the format; the only documented temporary exception is the
  explicitly tagged HVF `backend_private` GIC blob, which other backends must
  reject.
- Manifests carry a format version; consumers fail closed on versions or
  platform contracts they cannot satisfy.
- A future format-version bump needs an explicit compatibility and migration
  decision.
