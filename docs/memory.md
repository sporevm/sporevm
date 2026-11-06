# Memory And Local CoW Contract

SporeVM memory is portable through manifest chunk refs and fast locally through
optional same-host backing files. The chunk refs are the authority. Local
backing is acceleration metadata.

## Product sizing

SporeVM has two memory sizes: the initial guest-visible size and the maximum
guest-visible size. Fixed memory is the default, so omitting `--max-memory`
makes the two sizes equal:

```bash
# Fixed 512 MiB, the default.
spore run -- /bin/true

# Fixed 2 GiB.
spore run --memory 2gb -- /bin/true

# Grow-only virtio-mem from 512 MiB to 16 GiB.
spore run --memory 512mb --max-memory 16gb -- /bin/true

# The same elastic contract, using the documented initial default.
spore run --max-memory 16gb -- /bin/true
```

`--memory auto` has been removed. Migrate it to an explicit initial and maximum
pair, normally `--memory 512mb --max-memory 16gb` if the old 16 GiB elastic
ceiling was intended. `--memory SIZE` on its own now means fixed memory, not a
policy selection.

Fixed sizes must be positive and page-aligned. Elastic initial and maximum
sizes must also align to the 2 MiB virtio-mem block size, the maximum must be at
least the initial size, and the elastic region may span at most 8192 blocks
(16 GiB). Elastic memory is available only on the managed AArch64 kernel/initrd
contract and one-vCPU HVF or KVM backends; custom kernels and unsupported
backends fail closed. Fixed memory remains available on every supported
backend, including the experimental AMD64 profile at its documented 512 MiB
size.

The virtio-mem usable region grows with the requested size and never shrinks.
The guest may plug any non-overlapping blocks inside that usable prefix until
the requested amount is satisfied.

## Manifest Authority

`manifest.memory` records fixed-size BLAKE3-addressed chunks in the
`spore-disk-index-v2` encoding used for disk data. Each `chunk_ranges` entry
packs the digests of a run of contiguous nonzero chunks; `zero_ranges` counts
runs of all-zero chunks. RAM uses 2MiB chunks and the `memory/blake3`
namespace. Every nonzero chunk loaded from disk, a bundle, a cache, S3, or
HTTP(S) is verified against its digest before guest use.

`manifest.memory.backing` may name a local `ram.backing` file:

```text
memory:
  kind: spore-disk-index-v2
  logical_size: <maximum_memory_size>
  chunk_size: 2097152
  hash_algorithm: blake3
  object_namespace: memory/blake3
  chunk_ranges:
    - start: 0
      digests: <64 hex characters per chunk>
  zero_ranges:
    - start: 1
      count: <zero chunks>
  backing:
    kind: map-private-file-v0
    path: ram.backing
    size: <maximum_memory_size>
```

Fixed-memory manifests have no `memory_state`; their platform `ram_size`,
memory logical size, requested size, and captured guest-visible size are all
the same. Elastic captures, which are single-vCPU only, add backend-neutral
`memory_state` containing:

- `initial_size` and `maximum_size`, including initial RAM;
- `requested_size`, the guest-visible target requested from virtio-mem at capture;
- `captured_size`, initial RAM plus the blocks actually plugged by the guest;
- the 2 MiB `block_size`; and
- sorted, non-overlapping `plugged_ranges`, expressed as block offsets relative
  to the elastic region immediately after initial RAM.

Resume allocates the declared maximum, maps only initial RAM plus the captured
requested prefix, recreates the virtio-mem device, and restores its exact
plugged bitmap before vCPUs run. Raw KVM or Hypervisor.framework structures
never enter the manifest.

The backing file is never portable restore authority. Product restore maps it
only when `ram.backing.proof` validates against the canonical memory index
identity, opened file identity, backing metadata, and host-local runtime key.
The proof binds the file rather than its bytes, so saves fsync the backing
before writing it; the snapshot metrics report that as `finish_fsync_ms`.
That fingerprint uses the same canonical `spore-disk-index-v2` byte encoding as
disk and rootfs indexes. The fixed backing and proof paths are inspected without
following symlinks and must name regular files. Missing, symlinked, non-regular,
or size-mismatched optional paths, and stale, malformed, foreign-key, or
cryptographically mismatched proofs, fall back to chunks. Malformed
authoritative memory/index/backing metadata, allocation failure, unexpected
host I/O, corrupt chunks, and backend/platform/topology errors remain restore
errors; fallback does not hide failures outside the optional acceleration hint.

The proof is an HMAC keyed by a per-user key in the runtime root. It binds the
backing's device, inode, owner, size, and mtime, and proof creation re-stats
the opened backing before publishing so a file changed in between gets no
proof. Anyone who can rewrite the backing can also read the key, so the proof is
host-local provenance, not byte integrity. Proofs from other schemas, including
the removed fs-verity schema v2, fall back to chunks.

## Local CoW

KVM and HVF map a validated `ram.backing` fd with private mappings. Clean pages
can be shared by the host; guest writes fault into private CoW pages. This is
the same-host fork/fan-out fast path.

`spore fork` hard-links a proof-valid parent backing file into each child and
writes child-local proofs. The proven parent fd stays open across the batch; each
new child link is opened without following symlinks and must match every
proof-bound parent file-identity field before its proof is written. An
unavailable or invalid parent proof, a specifically classified unavailable
hard-link capability, or a conflicting optional child proof produces chunk-only
children. Malformed parent metadata, allocation failure, identity races, and
unexpected hard-link or proof-write I/O abort the fork instead of being hidden.

`spore pack`, `spore unpack`, and `spore pull` remain chunk-authoritative.
Bundles must not treat proof files as distribution authority.

## Dirty Tracking

Fresh product runs map guest RAM with demand-committed private mappings. Fixed
VMs allocate their configured size. Elastic VMs reserve the maximum host range,
map only the 512 MiB default (or explicit initial size) at boot, and grow the
guest mapping when memory pressure raises the virtio-mem requested size.

KVM dirty tracking uses dirty-log bitmaps plus explicit VMM-originated dirty
marking. Single-vCPU HVF uses write-protect faults plus explicit VMM-originated
dirty marking. Both backends seal dirty RAM through the shared `src/dirty_ram.zig`
path: zero chunks are elided, nonzero chunks are written by BLAKE3 id, and the
optional backing file is finalized as read-only local acceleration.

Capture seals the chunks dirtied since boot in one pass instead of scanning all
configured RAM, so suspend work is proportional to the guest's dirty set. That
cost must stay visible in benchmark and runtime stats.

Elastic capture currently uses the full-scan path so the maximum-sized portable
memory index and optional local backing remain authoritative for every plugged
range. Multi-vCPU HVF capture also uses the full scan. Fixed-memory KVM capture
and single-vCPU HVF capture retain the dirty-tracking fast path. Both paths
write chunks through `src/chunk_sealer.zig`, which fsyncs each chunk and its
directory entry before the manifest names it, and both fsync the backing file
before its proof is written.

## Current Limits

- `spore ls` reports initial and maximum memory, monitor process
  resident bytes on Linux/macOS, chunk size and total chunks, and local
  `ram.backing` logical/allocated bytes when a listed VM points at a local spore
  directory with a backing file. Ready dirty-tracked monitor VMs also report
  monitor-published nonzero and pending dirty chunk counters. Fields
  remain nullable when no cheap runtime source exists.
- Resume from chunks is portable; local backing is same-host acceleration only.
- Virtio-mem is grow-only. Unplug and reclamation remain unsupported.

## Validation

Useful focused checks:

```bash
test/smoke/run/auto-memory.sh
test/smoke/lifecycle/auto-memory.sh
test/smoke/fanout/counter.sh
test/smoke/run/capture.sh
```
