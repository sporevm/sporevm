# Spore Format

**Status:** v0 implemented (`src/spore.zig`), single-vCPU, HVF producer and
consumer. v0 carries no compatibility promise.

A spore is a sealed, content-addressed checkpoint of a VM. The format, not the
implementation, is the product: two SporeVM builds on different hypervisors
interoperate through this document.

## Layout

A spore is a directory:

```text
<spore>/
├── manifest.json
└── chunks/<blake3-hex>     # content-addressed data chunks
```

## Manifest v0

`manifest.json` fields (see `src/spore.zig` for the authoritative shapes):

- `version`: format version, currently 0. Consumers reject unknown versions.
- `platform`: contract the restoring host must satisfy exactly — `arch`
  (aarch64), `device_model_version`, `ram_base`, `ram_size`,
  `gic_dist_base`, `gic_redist_base`. Restore fails closed on any mismatch.
- `machine`: normalized architectural state for one vCPU — `gprs` (x0–x30),
  `pc`, `cpsr`, `fpcr`, `fpsr`, `simd` (32 Q registers as u64 pairs),
  `sys_regs` (EL1 context registers by architectural name), `icc_regs`
  (GICv3 CPU-interface registers by name), and `vtimer` as the guest's
  virtual counter value plus `CNTV_CTL`/`CNTV_CVAL`. Restore re-anchors the
  counter so guest time continues from the snapshot.
- `machine.gic_state_b64`: interrupt-controller state blob. This is the one
  field that is currently backend-opaque (hv_gic state); slice 4 replaces it
  with a normalized GICv3 representation or proves blob-level translation.
- `devices`: ordered virtio-mmio transport states (device id, status,
  feature negotiation registers, interrupt status, and per-queue size/ready/
  ring addresses/indices). Device order is part of the board contract.
- `memory`: `chunk_size` plus one entry per chunk — a blake3-hex chunk
  reference, or null for an all-zero chunk.

## Not yet captured in v0

- Disk contents: the spore references no disk state. Resume requires the
  same backing disk file, unmodified since the snapshot (same-host suspend
  semantics; Firecracker snapshots have the same constraint). The disk
  manifest is planned for the fork/fan-out slices.
- Access traces (lazy-restore prefetch hints): slice 5.
- Multi-vCPU machine state.
- Kernel identity in the platform contract (pinned-build enforcement).

## Invariants that hold regardless of version

- Chunk ids are BLAKE3-256 of chunk contents (`src/chunk.zig`); every chunk
  is verified against its id before use, from any source.
- Machine state is normalized architectural aarch64 state; raw KVM or
  Hypervisor.framework structures never appear in the format (the GIC blob
  is the documented temporary exception).
- Manifests carry a format version; consumers fail closed on versions or
  platform contracts they cannot satisfy.
- Pre-1.0 versions carry no compatibility promise.
