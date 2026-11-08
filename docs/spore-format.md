# Spore Format

**Status:** manifest format v8 (`src/spore.zig`) is the only accepted
contract. It covers one or more vCPUs and fixed or elastic memory for HVF and
KVM producers/consumers, with KVM portable multi-vCPU capture/restore and HVF
same-backend multi-vCPU capture/restore. Manifests from versions 0-7 are
rejected as too old and must be re-created.

A spore is sealed, content-addressed VM state. The format, not the
implementation, is the product: two SporeVM builds on different hypervisors
interoperate through this document.

Durable cache pins are deliberately outside this format. Machine-local saves
carry a host-private reference hard-linked to one cache-side ownership anchor,
and the cache owns the corresponding validated disk-index root. Neither pin ids
nor host paths are serialized into `manifest.json` or pushed spores. Raw
moves preserve ownership, while raw copies are rejected because they cannot
preserve the exclusive two-link identity. The cache has no global save-path
registry.

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

Spores saved from `spore run --image ... --save-checkpoint` may also require rootfs
storage from the local rootfs cache. The manifest records an immutable ext4
artifact identity, size, device binding, and provenance. For image-created
spores, that identity is the rootfs storage index digest and the manifest also
records `rootfs.storage` for the default chunked rootfs CAS path.
Rootfs bytes are not stored inside the spore directory today; `spore checkpoint resume`
opens and verifies the manifest-selected exact artifact or chunked storage
before boot.

`spore build` uses local build step records under the rootfs cache at
`build/steps/<step_key>.json`. These records are host-local cache metadata, not
portable spore format. The record envelope remains
`kind: "sporevm-build-step-v1"`; the current build-cache ABI is identified by
`builder_version: "sporevm-build-v9"`. Records have an inclusive 16 MiB bound
at publication and read time. Warm lookup and GC share a reader whose extra
byte is reserved as the overflow sentinel; a writer that would exceed 16 MiB
fails before atomic replacement, so every product-published record remains
readable by both consumers. A record binds `platform`, `step_key`,
`parent_index_digest`, `child_index_digest`, `instruction_kind`, canonical
instruction text, `input_digest`, `env_digest`, `workdir`, optional
`network_mode`, optional preparation fields, COPY destination policy, ordered
RUN cache-mount identity, executor identity for ordinary executor-backed
steps, optional typed `ssh_declared_absent` RUN state, and the child's `rootfs_storage`
descriptor.

`ssh_declared_absent: true` records only the accepted credential-free default
declaration. Its step key also binds the resolved RUN environment, including
BuildKit's inert default `SSH_AUTH_SOCK` value when applicable. Absence of the
field means no such declaration; it never names a socket, secret, transport,
or portable machine-state field.

Builder v9 retains v8's representation of rootfs capacity normalization as the
typed synthetic operation `PREPARE`, not as Dockerfile syntax. Its canonical instruction and
instruction kind are both `PREPARE`; `exact_target` and `producer_identity`
are required, length-framed step-key inputs alongside the exact parent index,
builder ABI, and platform. A PREPARE hit is valid only when the recomputed key
and explicit fields match, the child logical size equals `exact_target`, the
descriptor passes normal chunked-rootfs validation, `base_identity` and
`index_digest` both equal `child_index_digest`, and the selected rootfs CAS
completeness stamp is present. PREPARE lookup remains enabled under
`spore build --no-cache`; that flag continues to bypass Dockerfile instruction
reuse only.

Every RUN/COPY/ADD/WORKDIR key and record also binds `executor_identity`, the exact
kernel/initrd plus build-agent contract for the build. For managed defaults the
identity is derived from canonical kernel and embedded-initrd digests without
materializing either body on a cache hit. An executor miss reads the kernel
once, verifies those opened bytes against the bound digest, and boots the same
allocation; explicit overrides are eagerly loaded and retained. This prevents
two producer versions that happen to emit the same prepared index from
aliasing downstream step results.

A build holds the exclusive rootfs cache lock only to look up step records and
emit its context disk, seal a checkpoint, and publish the final image;
process-owned runtime leases keep every storage it uses from GC in between. A
quiesced rootfs checkpoint durably publishes verified objects first and its
canonical index second; only then does the build publish the completeness
stamp and atomically replace the step record. Final image metadata and the
mutable local ref are published after the selected storage is revalidated.
PREPARE records use the existing step-record GC root and introduce no portable
manifest, rootfs descriptor, index, or object kind.

Rootfs cache GC prunes records from older builder versions, malformed or
incomplete known records, and semantically stale builder-v9 records. Unknown
future record kinds or builder versions are preserved and conservatively retain
the rootfs CAS namespace.

The local image identity published by indexed-image producers such as
`spore build` and `spore run --commit-image` is distinct from the raw rootfs storage
identity. Publication first serializes the final
`ImageConfig` as canonical JSON with optional null fields omitted and the
deterministic struct field order owned by `src/image.zig`
(`architecture`, `os`, `config`, then runtime config fields `Env`,
`Entrypoint`, `Cmd`, `WorkingDir`, `User`, `OnBuild`). `config_digest` is
`blake3:<hex>` over two length-prefixed fields: the ASCII domain
`sporevm-indexed-image-config-v1` and those canonical config JSON bytes. The
published image digest is `blake3:<hex>` over three length-prefixed fields: the
ASCII domain `sporevm-indexed-image-v1`, the final `rootfs_storage.index_digest`
string, and the same canonical config JSON bytes. Each field is framed as an
unsigned 64-bit little-endian byte length followed by the exact bytes. The
local resolved ref and metadata path are keyed by that image digest, while the
metadata's `rootfs_storage` descriptor remains keyed by the raw rootfs index
digest used to boot the VM. `rootfs_storage` is the local rootfs metadata
field; portable spore manifests continue to use `rootfs.storage`.

To move one saved spore between hosts, `spore checkpoint push` it to an
[image store](image-format.md#spores) and `spore checkpoint pull` it on the other host.

## x86-64 Board Profile v0

`sporevm-x86_64-board-v0`, device-model version 1, is the frozen x86-64
Linux/KVM machine contract for fresh execution. It defines no AMD64 saved-state
format: capture, save, restore, resume, and fork are unavailable. The
aarch64-only manifest layout documented below is unchanged. Board-v0
supports one through eight vCPUs. Local APIC IDs are consecutive from zero,
vCPU 0 is the bootstrap processor, and IOAPIC ID 8 remains outside the vCPU ID
range. The experimental product profile currently narrows this board contract
to one vCPU and exactly 512 MiB of memory.

RAM is one page-aligned low-memory region starting at GPA zero, with a minimum
size of 64 MiB (`0x04000000`) and a maximum size of 2 GiB (`0x80000000`). The
current execution profile uses one KVM memory slot. The direct-boot E820 table
is exactly:

| GPA range | E820 kind | Purpose |
|---|---|---|
| `0x00000000..0x000003ff` | reserved | managed-kernel MP-table scan window |
| `0x00000400..0x0009fbff` | RAM | low conventional RAM |
| `0x0009fc00..0x000fffff` | reserved | legacy hole |
| `0x00100000..<ram_size` | RAM | remaining low RAM |

The Intel MP 1.4 floating pointer is at GPA `0x00000000` and names the
configuration table at `0x00000010`. The table publishes one through eight
enabled processors, the ISA bus, IOAPIC ID 8 at `0xfec00000`, identity-routed
ISA IRQs 0 through 15, ExtINT to BSP LINT0, and NMI to every LAPIC LINT1. KVM's
default routing maps GSI `i` to IOAPIC INTIN `i`, including PIT output on GSI
0. The maximum eight-vCPU table ends at `0x0000017c`, inside the reserved
bottom-1-KiB scan window and below the GDT.

Direct boot uses these fixed placements:

| Object | GPA | Contract |
|---|---:|---|
| GDT | `0x00000500` | 32-byte flat protected-mode GDT |
| zero page | `0x00007000` | one 4-KiB Linux boot-parameter page |
| kernel command line | `0x00020000` | at most 4096 bytes plus NUL, bounded by the bzImage header |
| protected-mode kernel payload | `0x00100000` | Linux 32-bit boot protocol 2.10 or newer |
| initrd | dynamically below the kernel/header ceiling | page-aligned, below `ram_size`, and disjoint from kernel load/runtime ranges |

The permanent non-RAM board ranges are:

| Range | Owner |
|---|---|
| `0xd0000000..0xd0000fff` | eight 512-byte virtio-mmio windows |
| `0xd0001000..0xd0001fff` | generation-device page |
| `0xfec00000..0xfecfffff` | IOAPIC |
| `0xfee00000..0xfeefffff` | local APIC |
| `0xfffbc000..0xfffbcfff` | KVM identity-map page |
| `0xfffbd000..0xfffbffff` | KVM three-page TSS region |

The eight virtio-mmio transport positions are fixed even when a transport is
unpopulated. The inventory is:

| Slot | MMIO base | GSI | Role/device |
|---:|---:|---:|---|
| 0 | `0xd0000000` | 5 | console (`3`) |
| 1 | `0xd0000200` | 6 | root block (`2`) |
| 2 | `0xd0000400` | 7 | context block (`2`) |
| 3 | `0xd0000600` | 8 | build block (`2`) |
| 4 | `0xd0000800` | 9 | cache block (`2`) |
| 5 | `0xd0000a00` | 10 | network (`1`) |
| 6 | `0xd0000c00` | 11 | vsock (`19`) |
| 7 | `0xd0000e00` | 12 | RNG (`4`) |

Virtio windows accept only 1-, 2-, and 4-byte MMIO accesses. Each transport
uses level-sensitive interrupt state: any write, including device reset, that
clears `interrupt_status` must lower its GSI. The generation device is at
`0xd0001000`, size `0x1000`, GSI 13, and retains the shared SPGN register
protocol version 1. It may additionally accept aligned 8-byte accesses. Its
x86-only poweroff doorbell is the exact aligned 32-bit write of `0x46464f50`
(`POFF`) at offset `0x020`; reads return zero, and any write touching that
register with another placement, width, or value fails closed.

Board-v0's complete permitted PIO set is value-sensitive: writes
`0x70 <- 0x0f`, `0x71 <- 0x0a`, `0x71 <- 0x00`, and `0x80 <- 0x00` continue;
a read from `0x64` returns zero; and `0x64 <- 0xfe` reports `guest_reset`.
Every tuple uses width 1 and count 1, and every other direction, port, width,
count, or value fails closed. The generation doorbell reports `guest_off`.
`KVM_EXIT_SYSTEM_EVENT` reset/shutdown remains a typed raw event, while raw
`KVM_EXIT_SHUTDOWN`, triple fault, and a halted guest are never reclassified as
reset or poweroff.

## Manifest Format v8

`manifest.json` fields (see `src/spore.zig` for the authoritative shapes):

- `version`: 8. Consumers read it before the rest of the manifest, reject
  versions 0-7 with a format-too-old error, and reject newer versions as
  malformed. Version 8 retains the version 7 fields but marks saved RAM whose
  guest agent supports client-owned `exec-v1` commands and cancels their
  process trees on disconnect. Re-create older checkpoints; changing their
  version field cannot upgrade the saved agent.
- `annotations`: optional opaque string map for namespaced caller metadata,
  such as `dev.buildkite.cleanroom.policy_hash`. Keys and values are UTF-8
  strings, values are not interpreted by SporeVM, and the serialized annotation
  object is capped at 64 KiB. Restore ignores annotations it does not know.
  `spore --json checkpoint inspect` returns these key/value pairs from local `.spore`
  artifacts after the same manifest validation, so callers can recover opaque
  metadata without sidecar files.
- `platform`: contract the restoring host must satisfy exactly — `arch`
  (aarch64), `cpu_profile`, `device_model_version`, `vcpu_count` (bounded by
  the shared SporeVM topology cap), `ram_base`, `ram_size`, `gic_dist_base`,
  `gic_redist_base`, `gic_redist_stride` (the redistributor frame stride used
  to validate the exposed GIC layout), and `counter_frequency_hz`. Restore
  fails closed on any mismatch. Every backend uses the board's GICv3 layout:
  the distributor at `0x08000000` (64 KiB) and one `0x20000` redistributor
  frame per vCPU from `0x08020000`. CPU profile `sporevm-aarch64-v0` is the
  current Apple-M/Graviton common denominator; KVM enforces it by masking RNDR
  before guest boot. Device model version 4 includes the fixed virtio-mmio
  range plus the generation MMIO device at `0x0c001000`, size `0x1000`, SPI 24
  / INTID 56. Elastic manifests attach one grow-only virtio-mem device and
  persist its normalized state; fixed manifests must not contain that device.
- `machine`: normalized architectural vCPU and interrupt-controller state, as
  an object with exactly one member: `single` when `platform.vcpu_count` is 1
  and `multi` when it is 2 or more. Both are described below.
- `devices`: ordered virtio-mmio transport states (device id, status,
  feature negotiation registers, interrupt status, and per-queue size/ready/
  ring addresses/indices). Device order is part of the board contract.
  Builder-only attachments, such as the read-only context disk used by
  `spore build` COPY execution, reuse the existing virtio-blk device type as
  additional transient virtio-mmio instances and are not serialized into the
  manifest. Rootfs capacity growth likewise adds no device, slot, register, or
  manifest field. A transient, non-resumable profile on the existing root
  virtio-blk device alone offers `VIRTIO_BLK_F_WRITE_ZEROES` (bit 14); ordinary
  attachments retain the frozen feature surface. The shared transport accepts
  only driver features that are a subset of the reconstructed device's offered
  set, latches the accepted set until reset, and validates selected/restored
  feature state before it can be serialized or applied to the device. HVF and
  KVM full-machine capture reject any transport offering bit 14, including one
  whose guest has not accepted it. Rootfs-only build/commit checkpoints use
  transport state only to prove queue quiescence and serialize the resulting
  canonical disk index, not the growth profile. The runtime profile advertises
  exactly one write-zeroes range capped at 4 MiB; a request is accepted only
  after negotiation and with an exact 16-byte header, one 16-byte range, a
  one-byte status, zero command-level sector, nonzero bounded sector count,
  and no flag other than `UNMAP`.
- `generation`: non-virtio generation MMIO device state — `generation`
  counter, `interrupt_status`, and `params_b64` (base64-encoded
  resume-parameter bytes with trailing zeroes elided). `spore checkpoint fork` increments
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
  generation interrupt. The shared SPGN register protocol remains version 1
  and occupies offsets `0x000..0x01f`; offsets `0x020..0x0ff` are reserved for
  architecture-owned board controls decoded before the shared device. The
  current aarch64 board defines no such controls, so those bytes remain inert.
  The frozen x86 controls are documented by the x86-64 Board Profile v0 above;
  no portable manifest names that board before a later format revision.
- `sessions`: optional low-level process/session handles captured with the VM.
  A handle is generic: `id`, `kind: "process"`, and stream capabilities for
  `stdin`, `stdout`, `stderr`, and `terminal`. `spore checkpoint resume` uses the
  `default` handle when present, or the sole recorded handle for captures of a
  resumed command that was started under a generated `run-*` id. The handle
  records guest-side capability only. Host stdin, PTY ownership, terminal mode,
  and the currently attached client are never part of the spore. Producers must
  write at most 16 handles; ids are 1-63 ASCII alphanumeric, dash, underscore,
  or dot characters.
- `exec_defaults`: optional command context for image-created named VMs. `env`
  is the retained OCI `Config.Env` list, bounded to 64 entries of at most 255
  bytes each, and `working_dir` is an optional absolute path of at most 255
  bytes. Named save and fork persist these defaults so restore, push and
  pull, and child VMs execute like the source image. Producers omit the
  field when no defaults exist, and absence means no saved execution-context
  defaults. Per-exec environment and working-directory overrides are
  intentionally excluded.

Every disk-index identity is the BLAKE3 digest of one exact canonical JSON
encoding, `spore-disk-index-v2`. Indexes of earlier kinds
(`spore-disk-index-v1`, `rootfs-block-index-v0`) fail as too old. `system gc`
keeps such an index while a record names it but reclaims the objects only it
referenced.

Top-level fields appear in this order: `kind`, `logical_size`, `chunk_size`,
`hash_algorithm`, `object_namespace`, `chunk_ranges`, then `zero_ranges`.
Each nonempty `chunk_ranges` entry has `start` followed by `digests`, a
concatenation of one lowercase 64-character BLAKE3 hex digest per contiguous
logical chunk. Each nonempty `zero_ranges` entry has `start` followed by a
positive `count`. Ranges are ordered, non-overlapping, non-adjacent within the
same class, and together cover every logical chunk exactly once. Packing
removes per-chunk JSON object and field-name overhead while keeping the whole
input bounded to 64 MiB. A dense 32 GiB disk is covered by the format's focused
capacity test.

The encoding uses UTF-8, LF line endings, two-space JSON indentation, `: `
between names and values, decimal integers, both coverage arrays even when
empty, and no trailing newline. Parsers reject equivalent JSON with different
member order, whitespace, escaping, omitted empty arrays, range splitting, or
digest case. Descriptor matching, range arithmetic, exact coverage, canonical
bytes, and index identity are validated before the index can authorize storage.

Known-zero disk growth and whole-chunk write-zeroes operations are encoded as
v2 `zero_ranges`; they create no payload object and do not expose whether
the transient source-map entry was clean or dirty. A partial-chunk zero
operation preserves the remaining bytes and verifies any lazy CAS boundary
source before mutation. The resulting `logical_size`, non-zero entries, and
explicit zero coverage determine a new canonical index identity. A mutable
head poisoned by a backend failure after a validated mutating block request
cannot be snapshotted, forked, exported, or published and has no serialized
representation.

- `memory`: sparse memory index in the disk-index encoding:
  `kind: "spore-disk-index-v2"`, `logical_size`, `chunk_size`,
  `hash_algorithm: "blake3"`, `object_namespace: "memory/blake3"`,
  `chunk_ranges`, and `zero_ranges`, followed by the optional `backing`. RAM
  keeps the 2MiB memory chunk size; disk indexes use 64KiB chunks. Each packed
  digest names a portable `chunks/<hex>` file, and validation requires every
  logical chunk to be covered exactly once by either range list. A manifest
  whose memory index has an earlier shape is rejected. `backing` is optional
  local acceleration metadata for same-host KVM/HVF fork/fan-out: `kind:
  "map-private-file-v0"`, `path: "ram.backing"`, and `size`. Chunks remain the
  portable verified source of truth; imported and cold spores materialize from
  chunks instead. Product restore paths (`spore checkpoint resume`, `spore run --checkpoint`, and
  named monitor restore) may automatically map `ram.backing` when the local
  `ram.backing.proof` validates against the canonical memory index identity,
  backing metadata, opened file identity, and host-local runtime key. Saves
  fsync the backing before writing its proof, because the proof binds the
  file's identity rather than its bytes; proofs from earlier schemas fall back
  to chunks. Missing,
  symlinked, non-regular, stale, foreign-key, size-mismatched, or
  cryptographically mismatched optional backing/proof inputs may fall back to
  chunks. Malformed authoritative memory/index/backing metadata, allocation
  failure, unexpected I/O, corruption, and backend/platform/topology errors
  remain errors. The proof is local provenance metadata; it is not a portable
  trust root and does not prove every RAM byte still matches the manifest's
  chunk refs. KVM and HVF map a validated fd `MAP_PRIVATE` to share clean parent
  pages across fork children while child writes fault into private CoW pages.
- `memory_state`: present only for elastic memory, which requires
  `machine.single`. It records
  `initial_size`, `maximum_size`, total `requested_size`, total
  `captured_size`, `block_size` (currently 2 MiB), and sorted
  `plugged_ranges`. Each range has `start_block` and `block_count` relative to
  the virtio-mem region immediately after initial RAM. Validation requires
  maximum greater than initial, all sizes within the declared bounds, exact
  2 MiB alignment, at most 8192 elastic blocks, canonical non-overlapping
  ranges, and `captured_size == initial_size + plugged blocks`. The portable
  memory index and optional backing cover `maximum_size`; `platform.ram_size`
  remains the initial boot RAM size. Restore allocates the maximum-sized
  portable RAM image, maps initial RAM, recreates the virtio-mem transport,
  maps the captured requested prefix, restores the exact plugged ranges, and
  only then starts vCPUs. Manifests without this member mean fixed memory where
  initial, maximum, requested, captured, and memory-index logical size all
  equal `platform.ram_size`, and must not contain a virtio-mem device.
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
  BLAKE3 identity of the canonical disk index bytes. The index itself records
  current index version `spore-disk-index-v2`, logical size, chunk size, hash
  algorithm, object namespace, packed non-zero chunk ranges, and explicit zero
  ranges; it does not repeat `base_identity` because that would make the index
  self-referential.
- `disk`: optional sealed writable root disk state for rootfs-backed captures.
  `kind` must be `"chunk-index-disk-v0"`; `device` binds the disk to the
  same virtio-mmio rootfs slot, `size` is the full disk size, and `base` is the
  BLAKE3 digest of a disk index in the rootfs CAS namespace.
  `chunk_size`, `hash_algorithm`, and `object_namespace` mirror the index
  descriptor and must be `64KiB`, `blake3`, and `rootfs/blake3` for the current
  disk backend. The index packs sorted non-zero chunks and explicit zero
  coverage into ranges and is restore authority for the writable disk bytes.
- `network`: optional requested network capability and policy. `kind` is
  `spore-net-v0`; `default_action` is `"deny"` when public egress is limited
  to the allow lists (empty lists deny it all), and writers omit it only for
  unrestricted egress. Readers also limit egress to the lists when any allow
  entry is present without `default_action`, so only a network with neither
  is unrestricted. `allow_cidrs` and `allow_hosts` record the legacy CLI egress
  allow policy, while `allow_host_ports` records exact DNS-learned host plus
  port rules and `bound_services` records restore-time guest service
  requirements by name, guest host, and guest port. The manifest does not carry
  live gateway state, TCP flows, DNS response caches, host socket paths,
  host port forwards, credential material, or helper process state. Resume and
  `spore run --checkpoint` must attach a fresh gateway that satisfies the recorded
  `requirements` and policy or fail closed. `spore --json checkpoint inspect` exposes the
  network kind, requirements, and bound-service requirements so callers can
  preflight restore-time bindings without parsing `manifest.json` directly.

### Machine state

`machine.single` records one vCPU: `gprs` (x0–x30), `pc`, `cpsr`, `fpcr`,
`fpsr`, `simd` (32 Q registers as u64 pairs), `sys_regs` (EL1 context
registers by architectural name), `icc_regs` (GICv3 CPU-interface registers by
name), `vtimer` as the guest's virtual counter value plus
`CNTV_CTL`/`CNTV_CVAL`, all in the platform's `counter_frequency_hz` tick
domain, and `gic`. Restore re-anchors the counter so guest time continues from
the snapshot only when the target backend exposes the same architected counter
frequency. Its `gic.kind: "gicv3"` carries a normalized single-vCPU GICv3
subset: distributor and redistributor register values by architectural MMIO
offset plus sampled PPI/SPI line levels. KVM currently emits and consumes this
portable shape.

`machine.multi` records `vcpus` and `gic`. Each `vcpus[]` entry records one
normalized aarch64 vCPU state: `index`, `mpidr`, `gprs`, `pc`, `cpsr`, `fpcr`,
`fpsr`, `simd`, `sys_regs`, `icc_regs`, and `vtimer`. The validator requires
one entry per `platform.vcpu_count`, stable array order
(`index == array position`), unique indexes, unique MPIDRs, and the normalized
MPIDR mapping from `src/aarch64/topology.zig`. New multi-vCPU captures store one
shared `vtimer.cntvct` value in every entry. Restore accepts unequal values by
using vCPU 0 as the machine counter authority and translating each absolute
`cntv_cval` so `cntv_cval - cntvct` remains unchanged modulo 64 bits. The
portable multi-vCPU GIC state uses `gic.kind: "gicv3_multi"`. It carries global
distributor registers, per-vCPU redistributor register arrays keyed by MPIDR,
and line levels where PPIs include an owning MPIDR and SPIs do not. Validation
rejects more redistributors than the 8-vCPU maximum, unknown register offsets,
duplicate redistributors, duplicate line records, PPIs without a known owner,
and SPIs with an owner. KVM emits and consumes this shape. Multi-vCPU
manifests do not support elastic memory.

Either shape may instead carry `gic.kind: "backend_private"`, a tagged
fail-closed escape hatch for temporary same-backend restore. HVF currently
stores `backend: "hvf"`, `format: "hv_gic_state_v0"`, and a base64 `hv_gic`
blob until its GICv3 mapping lands; other backends must reject that blob
before mutating VM state.

## Not Yet Captured

- General block-device state is still incomplete. The current writable disk
  contract is one rootfs-bound chunk index over verified rootfs CAS objects.
- Kernel identity in the platform contract (pinned-build enforcement).
- Durable disk/device identity fixup beyond the current diskless helper. The
  product initrd consumes generation params for hostname, mixes
  `resume_entropy_seed` into the kernel RNG, and applies host-provided
  start/resume time to the guest clock, but machine-id, MAC, and other
  disk-backed workload fixups are not final.
- Cross-frequency architected timer restore: the manifest records and enforces
  the counter frequency, but cannot translate a running Linux guest between
  different `CNTFRQ_EL0` domains.
- Live network flows and host port forwards: the manifest persists requested
  network capability and policy only. Active TCP flows, learned DNS answers, and
  host loopback listeners are dropped across capture, resume, and fork.
- Virtio-mem unplug and reclamation policy. Elastic manifests persist the
  grow-only requested size and exact plugged ranges, but unplug requests remain
  unsupported.
- Transient rootfs-growth block state: write-zeroes feature bit 14, its accepted
  feature latch, and in-progress growth requests are not a saved-machine
  contract. Both backends reject full-machine capture of the growth profile;
  rootfs-only checkpoints persist only the resulting canonical disk index.

## Invariants that hold regardless of version

- Chunk ids are BLAKE3-256 of chunk contents (`src/chunk.zig`); every chunk
  is verified against its id before use, from any source.
- Pushed spores carry no local RAM backing metadata: `spore checkpoint push` strips it
  and `spore checkpoint pull` refuses a manifest that has it. Pull checks the manifest
  against its ref, writes normal `chunks/<blake3>` files, and verifies every
  RAM chunk, the disk index and every disk object before writing a resumable
  spore manifest.
- Immutable rootfs artifacts and chunked rootfs storage are portable by digest,
  not by local path. The fd-backed rootfs cache uses a verify-at-install,
  trust-at-open contract inside the host-local cache trust domain. User-supplied
  bytes are content-verified before publication under their digest; resume then
  opens that installed entry read-only and fails closed if it is a symlink,
  is not a regular file, or has the wrong size, without rehashing trusted cache
  bytes on every open. For chunked manifests, the flat ext4 file is a
  materialization cache keyed by the storage index digest.
- Manifest-bound chunked rootfs storage descriptors are the authority for
  pull CAS installation and for rebuilding a missing flat rootfs cache
  entry. Rebuild opens the exact local versioned disk index named by
  `rootfs.storage.index_digest`, validates the index against that descriptor,
  reads only BLAKE3-verified local chunk objects, then publishes the assembled
  flat cache entry under the same index identity.
- Local RAM backing files and `ram.backing.proof` are same-host acceleration
  hints, not portable trust roots. Product restore paths treat a valid proof as
  local provenance for opening a backing fd; invalid or absent proof uses the
  chunk manifest path. Pulls remain chunk-authoritative, and proof
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
