# Memory And Local CoW Contract

SporeVM memory is portable through manifest chunk refs and fast locally through
optional same-host backing files. The chunk refs are the authority. Local
backing is acceleration metadata.

## Manifest Authority

`manifest.memory` records fixed-size BLAKE3-addressed chunks as the same sparse
index shape used for disk data. `chunks` contains sorted nonzero entries with
`logical_chunk` and `digest`; `zero_chunks` lists sorted all-zero logical chunk
numbers. RAM uses 2MiB chunks and the `memory/blake3` namespace. Every nonzero
chunk loaded from disk, a bundle, a cache, S3, or HTTP(S) is verified against
its digest before guest use.

`manifest.memory.backing` may name a local `ram.backing` file:

```text
memory:
  kind: spore-disk-index-v1
  logical_size: <ram_size>
  chunk_size: 2097152
  hash_algorithm: blake3
  object_namespace: memory/blake3
  chunks:
    - logical_chunk: 0
      digest: blake3:...
  zero_chunks: [1, 2, ...]
  backing:
    kind: map-private-file-v0
    path: ram.backing
    size: <ram_size>
```

The backing file is never portable restore authority. Product restore maps it
only when `ram.backing.proof` validates against the canonical memory index
identity, opened file identity, backing metadata, and host-local runtime key.
That fingerprint uses the same canonical `spore-disk-index-v1` byte encoding as
disk and rootfs indexes. The fixed backing and proof paths are inspected without
following symlinks and must name regular files. Missing, symlinked, non-regular,
or size-mismatched optional paths, and stale, malformed, foreign-key, or
cryptographically mismatched proofs, fall back to chunks. Malformed
authoritative memory/index/backing metadata, allocation failure, unexpected
host I/O, corrupt chunks, and backend/platform/topology errors remain restore
errors; fallback does not hide failures outside the optional acceleration hint.

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

Fresh product runs map guest RAM with demand-committed private mappings. The
default product memory policy is `--memory auto`, currently a 16GiB
guest-visible contract, so host cost must follow touched pages and dirty chunks,
not configured RAM.

KVM dirty tracking uses dirty-log bitmaps plus explicit VMM-originated dirty
marking. HVF uses write-protect faults plus explicit VMM-originated dirty
marking. Both backends seal dirty RAM through the shared `src/dirty_ram.zig`
path: zero chunks are elided, nonzero chunks are written by BLAKE3 id, and the
optional backing file is finalized as read-only local acceleration.

Caught-up suspend should not perform a full configured-RAM scan. Active-write
guests are different: suspend work is proportional to the unsealed dirty tail,
and that tail must stay visible in benchmark and runtime stats.

## Current Limits

- `spore ls` reports lifecycle memory policy, configured bytes, monitor process
  resident bytes on Linux/macOS, chunk size and total chunks, and local
  `ram.backing` logical/allocated bytes when a listed VM points at a local spore
  directory with a backing file. Ready dirty-tracked monitor VMs also report
  monitor-published nonzero and pending dirty chunk counters. Fields
  remain nullable when no cheap runtime source exists.
- Resume from chunks is portable; local backing is same-host acceleration only.
- On Linux filesystems with fs-verity support, schema v2 local backing proofs
  sign the kernel verity digest and restore re-measures the opened fd before
  mapping. Other filesystems keep the v1 local-provenance proof path.
- Persisted virtio-mem plug/unplug state and access-trace/readahead contracts
  are outside the current manifest format.

## Validation

Useful focused checks:

```bash
test/smoke/run/auto-memory.sh
test/smoke/lifecycle/auto-memory.sh
mise run smoke:counter-fanout
test/smoke/run/capture.sh
scripts/benchmark/kvm-dirty-tracking.sh --backend hvf --modes write-protect
scripts/benchmark/kvm-dirty-tracking.sh --backend kvm --modes dirty-log
```
