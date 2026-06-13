# Spore Format

**Status:** v0 implemented (`src/spore.zig`), single-vCPU, same-host HVF and
KVM producers/consumers. v0 carries no compatibility promise.

A spore is a sealed, content-addressed checkpoint of a VM. The format, not the
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
└── ram.backing             # optional local same-host RAM acceleration file
```

A local bundle is the first distribution form:

```text
<bundle>/
├── manifest.json           # portable manifest; local RAM backing stripped
├── chunkpack.index.json    # blake3 chunk id -> pack/offset/length/sha256
└── chunkpacks/000000.pack  # uncompressed logical chunks concatenated
```

Bundles are an implementation format for distribution, not a new machine-state
contract. The BLAKE3 ids in `manifest.json` remain the restore-time trust root;
the SHA256 values in the chunkpack index make each packed segment compatible
with blob-store and later OCI-style descriptor verification.

## Manifest v0

`manifest.json` fields (see `src/spore.zig` for the authoritative shapes):

- `version`: format version, currently 0. Consumers reject unknown versions.
- `platform`: contract the restoring host must satisfy exactly — `arch`
  (aarch64), `cpu_profile`, `device_model_version`, `ram_base`, `ram_size`,
  `gic_dist_base`, `gic_redist_base`, and `counter_frequency_hz`. Restore
  fails closed on any mismatch. CPU profile `sporevm-aarch64-v0` is the
  current Apple-M/Graviton common denominator; KVM enforces it by masking RNDR
  before guest boot. Device model version 4 includes the fixed virtio-mmio
  range plus the generation MMIO device at `0x0c001000`, size `0x1000`, SPI 24
  / INTID 56.
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
  `generation`, `fork_index`, `fork_count`, `fork_batch_id`, `vm_id`,
  `hostname`, `mac_seed`, and `mac_address`. Backend restore refreshes the
  params page at actual resume time with volatile `resume_time_unix_ns` and
  `resume_entropy_seed` values before reasserting the generation interrupt.
- `memory`: `chunk_size` plus one entry per chunk — a blake3-hex chunk
  reference, or null for an all-zero chunk. `backing` is optional local
  acceleration metadata for trusted same-host KVM fork/fan-out: `kind:
  "linux-map-private-file-v0"`, `path: "ram.backing"`, and `size`. Chunks
  remain the portable verified source of truth; unsupported backends,
  imported/cold spores, and normal untrusted restore must ignore `backing` and
  materialize from chunks instead. KVM same-host restore consumes backing as a
  trusted fd supplied by its caller, then maps it `MAP_PRIVATE` to share clean
  parent pages across fork children while child writes fault into private CoW
  pages. The current `kvm-boot --trust-ram-backing` harness opens the local
  `ram.backing` path as an interim adapter; the backend itself no longer
  resolves manifest paths.

## Not yet captured in v0

- Disk contents: the spore references no disk state. Resume requires the
  same backing disk file, unmodified since the snapshot (same-host suspend
  semantics; Firecracker snapshots have the same constraint). The disk
  manifest is planned for the fork/fan-out slices.
- Access traces: the KVM lazy-restore harness can write a local first-touch
  trace for measurement, but v0 does not persist access traces or prefetch
  hints in the manifest.
- Multi-vCPU machine state.
- Kernel identity in the platform contract (pinned-build enforcement).
- Durable disk/device identity fixup beyond the current diskless helper. The
  fork-aware smoke initrd consumes generation params for hostname, machine-id,
  MAC, entropy, and clock fixups, but the product guest-agent contract for
  disk-backed workloads is not final.
- Cross-frequency architected timer restore: v0 records and enforces the
  counter frequency, but cannot translate a running Linux guest between
  different `CNTFRQ_EL0` domains.

## Invariants that hold regardless of version

- Chunk ids are BLAKE3-256 of chunk contents (`src/chunk.zig`); every chunk
  is verified against its id before use, from any source.
- Chunkpack bundles are portable only after local RAM backing metadata has been
  stripped. `spore unpack` reconstitutes normal `chunks/<blake3>` files and
  fails closed when a pack segment's SHA256 or logical BLAKE3 id mismatches.
- Local RAM backing files are same-host acceleration hints, not portable trust
  roots. The current path/symlink form is an interim KVM harness adapter, not a
  sealed-fd security boundary. Consumers that need portable or untrusted restore
  must use the chunk manifest path. The planned monitor boundary passes a
  sealed RAM-backing fd explicitly, rather than trusting a backing file by
  pathname.
- Machine state is normalized architectural aarch64 state. Raw KVM structures
  never appear in the format; the only documented temporary exception is the
  explicitly tagged HVF `backend_private` GIC blob, which other backends must
  reject.
- Manifests carry a format version; consumers fail closed on versions or
  platform contracts they cannot satisfy.
- Pre-1.0 versions carry no compatibility promise.
