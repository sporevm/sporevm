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

## Passive free-page return

On AArch64 HVF and KVM, `spore run --free-page-reporting` and
`spore vm create NAME --free-page-reporting` opt into a reporting-only
virtio-balloon device. The API option and `vm create --options` JSON field are
`free_page_reporting` (default false). This works with fixed memory and with
the existing grow-only profile. It never inflates a balloon, unplugs memory,
changes guest MemTotal, or changes the configured vCPU count. The guest needs
`CONFIG_VIRTIO_BALLOON` and `CONFIG_PAGE_REPORTING` (included in managed kernels).
Guests configured to require page-poison preservation cannot negotiate this
profile; no page-poison feature is offered.

The physical virtqueues are inflate 0, deflate 1, and reporting 2. Linux
6.1.191's [balloon driver](https://github.com/gregkh/linux/blob/v6.1.191/drivers/virtio/virtio_balloon.c#L496-L540)
uses logical array slot 4 for reporting, but leaves the absent stats/hint
names NULL. The [virtio-mmio transport](https://github.com/gregkh/linux/blob/v6.1.191/drivers/virtio/virtio_mmio.c#L438-L475)
skips those entries and assigns consecutive physical queue indices. Do not
reserve empty physical slots 2 and 3: the guest would not find reporting.
The real-kernel smoke gate's reporting-off/on checkpoint comparison exercises
this discovery path, rather than relying only on a synthetic queue setup.

Linux reports free buddy blocks asynchronously, not every page freed by an
application. Fragmented free pages and reclaimable page cache are not forced
out. A returned page incurs fresh host allocation/zeroing faults if the guest
uses it again: measure workload throughput, not just idle RSS, before enabling
this option broadly.

Only complete 2 MiB-aligned ranges inside a report are returned. Host RAM bases
are also 2 MiB aligned. Every segment must lie within actually mapped guest
RAM; a report touching an unmapped hotplug tail is ignored and acknowledged as
a whole. Requested growth alone does not make a range reportable. Partial
ends stay intact, avoiding splits of live huge pages. KVM advises replacement
ranges as THP-eligible; this is best effort, not a guarantee of huge-page
allocation. Returning a huge page necessarily releases
that page; a later touch may allocate another one. This does not add hugetlb
support or change sharing/COW costs for live parent pages.

The runner parks every vCPU and drains disk workers before changing backing.
Each pause consumes one report chain, coalescing overlapping or adjacent aligned
ranges. A pause therefore makes at most 64 mapping replacements and returns no
more than the mapped RAM size in unique bytes; repeated descriptor aliases
cannot amplify that work. Other chains stay pending for later pauses, allowing
vCPUs to resume and monitor control requests to run between batches.
HVF unmaps the reported GPA, replaces its host mapping with private anonymous
zero RAM, then remaps it; KVM retains memslot addresses and invalidates old
translations through the host MMU notifier path. Neither backend punches holes
in parent backing. `MADV_DONTNEED` alone is insufficient: on private file RAM it
can expose the parent's old bytes rather than zeroes.

Reported zeroes are host writes for dirty tracking. Mapping replacement is
serialized with checkpoint sealing, and HVF restores write protection before
resuming. Transport checkpoints retain negotiation, queue indices, pending
descriptors and interrupts. Restore infers attachment from the manifest, so
omit the opt-in flag on restore. Pending reports remain owned by the device
until acknowledgement; completed reports are never replayed or remembered as
authority to discard pages again. Fork children reclaim only their private
mappings; the shared parent and siblings remain unchanged.

`mise run smoke run/free-page-reporting` exercises allocation, free, re-touch,
single-/multi-vCPU execution, save, fork, local-backing restore, verified-chunk
restore and parent immutability. It prints host RSS and guest allocation-work
throughput separately. `SPORE_REPORTING_BENCHMARK=1` adds reporting-disabled
throughput baselines; `SPORE_REPORTING_CYCLES` increases samples. The normal
gate retains the asserted reporting-off/on checkpoint control without the
extra benchmark runs. No automatic capacity-shrink policy is implemented.

## Manifest Authority

`manifest.memory` records fixed-size BLAKE3-addressed chunks in the
`spore-disk-index-v2` encoding used for disk data. Each `chunk_ranges` entry
packs the digests of a run of contiguous nonzero chunks; `zero_ranges` counts
runs of all-zero chunks. RAM uses 2MiB chunks and the `memory/blake3`
namespace. Every nonzero chunk loaded from disk, a cache, or an image store is
verified against its digest before guest use.

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

A default `checkpoint pull` restores from chunks, which copies nonzero RAM
into each child's anonymous mapping. Use `checkpoint pull STORE/REF --output
DIR --local-ram-backing` to build and prove the shared sparse file once on the
destination. It costs an additional local copy of nonzero logical RAM on disk
(including repeated chunk occurrences) and an upfront verification/write/fsync
pass. Retain one pulled parent for its children; separate pulls create separate
backing files and do not share physical clean pages merely because hashes match.
Private writes still cost memory per child, and child PSS excludes untouched
backing page cache. See [the pull contract](image-format.md#spores).

`spore checkpoint fork` hard-links a proof-valid parent backing file into each child and
writes child-local proofs. The proven parent fd stays open across the batch; each
new child link is opened without following symlinks and must match every
proof-bound parent file-identity field before its proof is written. An
unavailable or invalid parent proof, a specifically classified unavailable
hard-link capability, or a conflicting optional child proof produces chunk-only
children. Malformed parent metadata, allocation failure, identity races, and
unexpected hard-link or proof-write I/O abort the fork instead of being hidden.

`spore checkpoint push` and `spore checkpoint pull` remain chunk-authoritative and do not treat
proof files as distribution authority.

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

- `spore vm ls` reports initial and maximum memory, monitor process
  resident bytes on Linux/macOS, chunk size and total chunks, and local
  `ram.backing` logical/allocated bytes when a listed VM points at a local spore
  directory with a backing file. Ready dirty-tracked monitor VMs also report
  monitor-published nonzero and pending dirty chunk counters. Fields
  remain nullable when no cheap runtime source exists.
- Resume from chunks is portable; local backing is same-host acceleration only.
  Chunk resume writes only non-zero chunks into fresh anonymous RAM, so zero
  chunks stay uncommitted until the guest touches them.
- Virtio-mem is grow-only. Capacity shrink and unplug remain unsupported;
  opt-in free-page reporting returns backing without changing capacity.

## Validation

Useful focused checks:

```bash
test/smoke/run/auto-memory.sh
test/smoke/lifecycle/auto-memory.sh
test/smoke/fanout/counter.sh
test/smoke/run/capture.sh
```
