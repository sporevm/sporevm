# Memory And Local CoW Contract

SporeVM memory is portable through manifest chunk refs and fast locally through
optional same-host backing files. The chunk refs are the authority. Local
backing is acceleration metadata.

## Manifest Authority

`manifest.memory` records fixed-size BLAKE3-addressed chunks. A chunk entry is
either a `blake3:<hex>` reference or `null` for an all-zero chunk. Every chunk
loaded from disk, a bundle, a cache, S3, or HTTP(S) is verified against its
digest before guest use.

`manifest.memory.backing` may name a local `ram.backing` file:

```text
memory:
  chunk_size: 2097152
  chunks: [null, "blake3:...", ...]
  backing:
    kind: map-private-file-v0
    path: ram.backing
    size: <ram_size>
```

The backing file is never portable restore authority. Product restore maps it
only when `ram.backing.proof` validates against the manifest memory fingerprint,
opened file identity, backing metadata, and host-local runtime key. Missing,
corrupt, foreign-key, symlinked, or mismatched proofs fall back to chunks.

## Local CoW

KVM and HVF map a validated `ram.backing` fd with private mappings. Clean pages
can be shared by the host; guest writes fault into private CoW pages. This is
the same-host fork/fan-out fast path.

`spore fork` hard-links a proof-valid parent backing file into each child and
writes child-local proofs. If hard-linking, parent proof validation, or child
proof writing fails, children omit backing metadata and resume from chunks.

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
- Linux fs-verity could strengthen backing-file integrity later, but it should
  not become a user-facing mode.
- Multi-vCPU and access-trace/readahead contracts are outside the current
  manifest format.

## Validation

Useful focused checks:

```bash
scripts/smoke-run-auto-memory.sh
scripts/smoke-lifecycle-auto-memory.sh
mise run smoke:counter-fanout
scripts/smoke-run-capture.sh
scripts/benchmark-kvm-dirty-tracking.sh --backend hvf --modes write-protect
scripts/benchmark-kvm-dirty-tracking.sh --backend kvm --modes dirty-log
```
