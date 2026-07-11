---
status: active
last_reviewed: 2026-07-11
spec_refs:
  - docs/rootfs.md
  - docs/filesystem.md
  - docs/spore-format.md
  - SECURITY.md
  - src/build.zig
  - src/build/exec.zig
  - src/runtime_disk.zig
  - src/chunk_mapped_disk.zig
  - src/virtio/blk.zig
  - guest/minimal-initrd/agent.c
  - src/disk_index.zig
related_plans:
  - docs/plans/spore-build.md
  - docs/plans/native-ext4-writer.md
  - docs/plans/unified-chunk-disk.md
  - docs/plans/run-image-commit.md
---

# Fast, Transparent Rootfs Capacity For `spore build`

## Summary

Make rootfs growth an automatic storage operation rather than an expensive
guest command or a filesystem-creation mode the user must anticipate.

On the first build use of a rootfs smaller than SporeVM's build-capacity
target, the host extends the chunk-mapped disk with clean, known-zero chunks.
The ephemeral build VM exposes virtio-blk `WRITE_ZEROES`; Linux performs the
ext4 grow through `EXT4_IOC_RESIZE_FS`; and zeroing requested by ext4 remains
zero-map metadata instead of becoming guest payload I/O or dirty CAS work. The
trusted initrd agent issues the ioctl directly. The selected rootfs does not
need `/bin/sh`, e2fsprogs, or `resize2fs`.

The grown filesystem is a normal canonical rootfs index. SporeVM records the
derivation from `(parent index, exact target, preparation ABI)` to that complete
index as a typed synthetic `PREPARE` operation using the existing build step
record, completeness, publication, and GC machinery. Unrelated Dockerfiles and
`--no-cache` builds can therefore reuse preparation without another cache
namespace or weakening Dockerfile cache semantics.

Ordinary users configure nothing. The default policy grows a valid rootfs
smaller than 16 GiB to exactly 16 GiB once and preserves the exact size of an
image already at or above 16 GiB. It never recursively doubles or adds
headroom to a descendant. There is no build-capacity flag, inode knob,
headroom formula, compact/build profile, or resize-tool path in the user
contract.

Sixteen GiB is both the v1 automatic target and automatic-growth cap. This is
the largest simple default that leaves substantial room below the current
64 MiB canonical-index limit even if every chunk becomes nonzero: a dense
16 GiB index is about 33.39 MiB, while a dense 32 GiB index is about 66.89 MiB
and cannot be encoded. Larger existing images remain usable at their exact
size, but `spore build` does not automatically enlarge them.

## User Outcome

The intended behavior is deliberately boring:

```text
spore build ...
```

- grows a small valid ext4 base automatically;
- works for OCI imports, existing local images, committed images, and cached
  intermediates without a tool inside those images;
- keeps zero capacity sparse in the host file and rootfs CAS;
- reuses an already-prepared base even when Dockerfile step-cache reads are
  disabled;
- never grows an already-normalized image again, and leaves parents at or
  above the automatic cap unchanged;
- fails before publishing a new step or destination ref if growth is unsafe or
  unsupported; and
- reports block/inode exhaustion as terminal for that invocation, without
  retrying a potentially side-effecting RUN or exposing filesystem machinery.

## Current Progress

- **Implemented on the active branch:** clean-known-zero growth and range
  zeroing, growth-session-only virtio-blk `WRITE_ZEROES`, direct
  `EXT4_IOC_RESIZE_FS` through the managed initrd, the fixed 16 GiB policy,
  builder-v7 typed `PREPARE` reuse, and the same primitive for
  `spore run --commit --disk-size`.
- **P0 kernel behavior (2026-07-11, M4/HVF):** the pinned Linux 6.1.155 guest
  completed the current 16 GiB product grow through 124 type-13 requests
  covering 520,093,696 bytes, all `UNMAP`/OK, with no ordinary all-zero OUT.
  The forced-unsupported control produced 124 `UNSUPP` responses and exactly
  520,093,696 bytes of ordinary all-zero OUT, proving both the native fast path
  and the intended negative control. Six seconds after resize, both paths
  showed no additional block writes. The checksum/lazy negative control did
  show background writes and failed before publication.
- **P1 clean-tail result (2026-07-11, M4/HVF):** the old 16 MiB -> 8,208 MiB
  checkpoint sealed 131,073 chunks, spent 3,292 ms zero-scanning, and took
  3,376 ms total. Clean-zero growth sealed one metadata chunk, performed no
  zero scan, and took 7 ms.
- **P2/P3 product-path result (2026-07-11, M4/HVF):** five isolated
  instrumented ReleaseSafe 16 GiB probes took 362, 365, 358, 359, and 362 ms
  (362 ms median, 365 ms nearest-rank p95). Explicit host instrumentation puts
  resize-through-CAS-publication at 127, 126, 125, 125, and 126 ms (126 ms
  median, 127 ms p95). Median peak host RSS was 174,211,072 bytes (166.1 MiB).
  The harness's literal uninstrumented default-path mode took 354, 356, 351,
  373, and 357 ms (356 ms median, 373 ms p95) for the same two-RUN probe.
  Five uninstrumented default-path runs of the original
  ARG/ENV/WORKDIR/two-COPY/one-RUN shape, cloned from the same exact compact
  parent into isolated caches, took 0.44, 0.44, 0.43, 0.43, and 0.44s (0.44s
  median/p95). All five emitted the same PREPARE key, producer identity, and
  child index. Fully warm samples were 0.13s; three one-COPY-plus-RUN changes
  were 0.44, 0.40, and 0.39s (0.40s median).
  A shared `PREPARE` hit under `--no-cache` took 0.16s, issued no resize or
  `WRITE_ZEROES`, and still executed Dockerfile steps. Fully warm builds avoid
  boot; the edited incremental smoke boots once, executes four steps, and
  performs no resize.
- **Native KVM result (2026-07-11, Linux ARM64/KVM):** branch commit `ab631dd`
  passed native tests and ReleaseSafe assembly. The build/run smoke covered
  first preparation, prepared reuse, warm, `--no-cache`, and incremental
  paths functionally; the 2.25 GiB sparse-COPY smoke, run-commit lifecycle
  smoke including save/fork/restore, and local pull also passed. Five
  six-second P0 samples each completed the same 124 type-13/UNMAP requests
  covering 520,093,696 bytes, with no ordinary all-zero OUT, errors, or
  post-resize writes. Five instrumented P3 misses took
  529 ms median / 532 ms p95; preparation-through-publication took 211 ms
  median / 218 ms p95, and median peak RSS was 140.7 MiB. A separate
  same-exact-parent run produced the same PREPARE key, parent index, prepared
  child index, and producer identity in all five samples. The literal
  uninstrumented two-RUN harness took 525 ms median / 527 ms p95. This is a
  useful absolute observation, but it is not comparable to the historical
  macOS/HVF 0.36s prepared baseline: the KVM cold gate requires paired default
  and prepared/no-growth samples of the exact historical fixture on the same
  host and commit. KVM warm and incremental paths passed functionally, but
  their performance gates also remain unmeasured.
  The validated WRITE_ZEROES failure smoke emitted its intended failure
  diagnostic but then aborted in KVM vCPU teardown: duplicate cleanup
  ownership in `src/kvm/vm.zig` deinitialized the vCPU slice twice on a
  post-start error. This bug predates the branch, but abnormal termination
  violates the fail-closed release gate and makes native KVM validation
  incomplete.
- **P4 canonical-index envelope (2026-07-11):** a fully nonzero 16 GiB index
  is about 33.39 MiB, leaving 30.61 MiB (47.8%) below `max_index_bytes`. A
  fully nonzero 32 GiB index is about 66.89 MiB and is rejected; the largest
  fully dense current-format disk is about 30.62 GiB. At 64 GiB the index
  fails above roughly 42.67% nonzero chunks. Sixteen GiB is therefore the v1
  target and cap; 32/64 GiB remain format stress points, not user promises.
- **Correctness evidence (2026-07-11, M4/HVF):** native and checksum-enabled
  grown images pass `e2fsck -fn`; multi-GiB sparse COPY, build-cache/no-cache,
  run-commit grow/reuse/shrink rejection, prepared-image save/restore, and
  bundle pack plus flat materialization pass. The retained disk-size smoke now
  injects a validated WRITE_ZEROES backend failure during build preparation,
  proves the unpublished head is poisoned, and verifies the destination ref,
  PREPARE/step records, indexes, objects, and completeness stamps are unchanged.
  Format-valid partial-final-chunk parents preserve and CAS-verify the old
  prefix, expose a sparse-zero suffix, and produce the same canonical snapshot
  as a full-rescan oracle across base/CAS/zero/overlay sources.
- **Remaining release evidence:** native KVM is now measured but not green.
  Repair the vCPU teardown ownership bug, require the forced-failure smoke to
  return the normal CLI build-error status rather than merely printing the
  expected diagnostic, rerun the affected KVM paths, and resolve the tiny-cold
  gate with paired same-host samples of the exact historical fixture. Record
  KVM warm and incremental timings as part of that rerun. Exploratory HVF runs
  exercised a verified 512 MiB RUN-generated file and real block/inode ENOSPC;
  both exhaustion cases produced terminal diagnostics without retry and left
  the destination ref unchanged. Those one-off runs establish feasibility but
  are not retained as reproducible repository evidence, so large RUN and both
  ENOSPC modes remain release gates until an identical smoke records them.
  Concurrency/publication fault injection, prepared-output-specific
  pack/unpack/pull identity, and commit-as-a-later-build-base also remain
  explicit matrix items.

## Original Path And Cost Boundaries

At the branch base, the automatic target was anchored to the selected base and
computed:

```text
round_up(max(2 * parent_logical_size,
             parent_logical_size + 8 GiB),
         rootfs_chunk_size)
```

On the first executor miss, that implementation enlarged `ChunkMappedDisk`,
booted the guest, executed `resize2fs /dev/vda` over a dedicated control
stream, and then started Dockerfile work.

Manual ReleaseSafe measurements on macOS/HVF at commit
`b711b5578be30e49732f1628f5ecf6ad8e9c01fd` used the same Alpine 3.20
ARG/ENV/WORKDIR/two-COPY/one-RUN fixture, runnable outputs, and isolated
caches:

| Scenario | Median | Samples or comparison |
|---|---:|---|
| Docker Buildx cold, no cache | 0.58s | 0.66s, 0.58s, 0.51s |
| Spore default cold, no cache | 4.17s | 4.10s, 4.33s, 4.17s |
| Spore with an existing exact 10 GiB base and no pending growth | 0.36s | 0.36s, 0.36s, 0.36s |
| Prepared Spore warm | 0.09s | median of three |
| Prepared Spore after one COPY input changed | 0.34s | Docker: 0.77s |

The prepared case used hidden `--disk-grow-target 10737418240` only to make
the requested target equal the base's existing logical size. It is evidence
about the no-growth path, not a proposed user feature.

The relevant path was revalidated on 2026-07-11 against `origin/main` commit
`8790d6ae6ad8f027616f28908a2d210abbb8c0a3`:

1. `ChunkMappedDisk.grow` appended every new 64 KiB chunk as `.zero_dirty`.
2. The first checkpoint therefore reads and zero-scans the entire appended
   tail before it can encode the same chunks as zero.
3. The native tiny Alpine filesystem has four 128 MiB groups and 16,384
   inodes per group. Growing 512 MiB to 8.5 GiB adds 64 groups; their 4 MiB
   inode tables total about 256 MiB.
4. In the managed Linux 6.1.155 source, online ext4 growth calls
   `sb_issue_zeroout` for the new inode tables used by Spore's native feature
   profile. The old virtio-blk profile advertised no block features, so the
   block layer fell back to ordinary zero-page writes instead of expressing
   that work as `WRITE_ZEROES` to the chunk map.
5. Checksum/uninitialized-group external filesystems can instead leave new
   inode tables for the mounted filesystem's lazy-init worker. That background
   work can race a preparation checkpoint or later Dockerfile step unless the
   build mount disables lazy init or explicitly waits for it.
6. `src/build/exec.zig` launched `resize2fs /dev/vda` rather than using the
   trusted initrd agent's existing ioctl/control-request seam.

The 3.81s aggregate delta is therefore bounded by two separate linear paths:

- guest/kernel zeroing and metadata I/O during ext4 growth; and
- host snapshot work proportional to appended logical bytes rather than
  changed metadata.

The implementation removes both causes independently: clean known-zero growth
removes the second path, and `WRITE_ZEROES` removes the payload cost from the
first. The forced-unsupported control demonstrates the latter boundary by
restoring the exact 256 MiB ordinary-zero fallback.

## Design Principles

In priority order:

1. **Fast by construction.** Work should be proportional to ext4 metadata
   changed and canonical index entries produced, not zero capacity added.
2. **Transparent for normal builds.** A small base should become build-capable
   without image preparation instructions or guest packages.
3. **One maintainable filesystem authority.** Linux remains responsible for
   online ext4 correctness; SporeVM supplies efficient block semantics.
4. **Minimal public policy.** One fixed automatic target/cap and no build
   tuning knobs. No matrix of profiles or overrides.
5. **Use SporeVM's architecture.** Known-zero chunks, dirty-only sealing,
   canonical full-index emission, and CAS reuse should make growth cheaper
   than it is on a generic flat block device.
6. **Fail closed.** Malformed requests, unsupported filesystem state, cache
   corruption, failed growth, failed freeze, and failed publication leave the
   source and destination refs unchanged.

## Goals

- Bring the tiny cold build to within 150 ms of a paired prepared/no-growth
  baseline on the same host and commit. On the reference M4/HVF host, the
  historical prepared baseline is 0.36s and the preferred cold median is at
  or below 0.50s.
- Remove the selected rootfs's dependency on `resize2fs` and `/bin/sh` for
  capacity growth.
- Make appended zero capacity create no proportional CAS payload and no
  proportional snapshot sealing work.
- Automatically handle imported OCI rootfs images, locally committed images,
  cached intermediate states, and existing compact images through the same
  build path.
- Preserve canonical rootfs/index identity, exact object verification,
  atomic publication, sparse physical allocation, and backend-neutral disk
  behavior.
- Avoid recursive multiplication or additive growth across image lineage.
- Keep normal build CLI/configuration unchanged; expose no capacity tuning
  surface until a larger checkpoint-safe format is designed and justified.
- Keep block and inode ENOSPC terminal for the current invocation and
  actionable for the next invocation.

## Non-Goals

- Infinite or reactive autoscaling after arbitrary RUN code has started.
- Retrying a RUN after ENOSPC; that can repeat external network/service side
  effects.
- A general host-side ext4 implementation in the first version.
- Changing the portable rootfs index or adding another persistent disk layer.
- Resizing the disk underneath a restored RAM snapshot or live saved VM.
- Exposing ext4 block-group, inode-density, resize-tool, or virtio tuning to
  users.
- Making exact-capacity microbenchmark hooks part of the default product path.
- Making `spore run --commit --disk-size` gate the initial build-path
  experiments. It must converge on the shared primitive before release rather
  than shipping two long-lived resize implementations.

## Invariants

1. The source rootfs index is immutable. Growth creates a new complete index
   and never rewrites the parent or its objects.
2. `RootfsStorage.logical_size`, disk-index logical size, sparse block-device
   capacity, and grown ext4 geometry agree for every published prepared base.
3. Every logical chunk has exact canonical coverage. Every nonzero digest is
   verified before use and every new object is durable before its index and
   completeness stamp become reachable.
4. A clean appended zero is distinguishable from a dirty operation that
   changes old nonzero bytes to zero. The latter must replace the parent entry
   in child identity, but neither state needs a payload read or zero scan.
5. Under a fully validated parent index, `parent_digests[i] == null` means the
   canonical parent chunk is zero; it never means unknown. Growth may append a
   null digest only with source state `.zero`, and the child index must emit
   explicit `zero_chunks` coverage for the entire appended tail.
6. Capacity affects rootfs bytes and therefore `H(index)`. No mutable hint can
   select different bytes under the same identity.
7. Preparation cache hits validate their record, target, output index, and
   completeness stamp. Missing or corrupt state is a miss or a hard failure,
   never best-effort reuse.
8. The default target is an idempotent absolute-capacity quantum policy, not a
   multiplier or additive reserve. Applying it to an already-normalized child
   returns the same size.
9. No failure publishes a `PREPARE`/Dockerfile step record or
   destination image ref that names incomplete storage.

## Considered Designs

### A. Storage-Aware Kernel Resize — Recommended

Extend the sparse chunk disk with clean zeros, let Linux grow ext4 through a
direct ioctl, and make its zeroing requests map to chunk-map zero operations.

**Why it fits**

- Linux remains the ext4 implementation, including imported/external writer
  layouts, partial groups, backup superblocks, and future filesystem features.
- SporeVM implements only block semantics it can make unusually cheap.
- Existing source-less local images are handled transparently.
- It removes the guest userspace package dependency without adding a host
  e2fsprogs distribution dependency.
- The device and control implementation is shared by HVF and KVM.

**Risks**

- `WRITE_ZEROES` is new attacker-controlled virtqueue input and requires full
  validation and fuzz coverage.
- Kernel/initrd changes may affect prepared bytes; preparation identity and
  reproducibility must be measured rather than assumed.
- Explicit zero coverage and source maps still scale with logical capacity.

### B. CAS-Native Host ext4 Grower — Fallback

Derive a new index directly from a validated Spore-native ext4 layout, reusing
parent digests and synthesizing only changed metadata chunks.

This can be even faster and deterministically producer-owned. The current
native 4 KiB/128 MiB-group/32-byte-descriptor profile can grow a compact image
to 16 GiB without adding a group-descriptor block. It is nevertheless a new
attacker-influenced ext4 parser/mutator, has a sharp initial layout boundary,
and does not naturally cover external-writer or older imported images.

**Decision:** keep as the measured fallback if Design A misses its latency,
quiescence, filesystem-semantics, or compatibility gates. Bounded timestamp
variance alone does not justify a second grower. Do not build both paths
speculatively.

### C. Capacity At Filesystem Creation — Complementary, Not Default

Fresh OCI/tar materialization can create a generous filesystem at birth. This
is simple for new bases and remains a possible import optimization.

It does not transparently handle existing small images, local commits, or
source-less states. Different native/external writers can also produce
different filesystem geometry for the same nominal capacity. Requiring users
to choose compact/build/exact modes creates configuration and cache variants
without solving the compatibility path.

**Decision:** retain as an optional producer optimization only after the
normalization contract is stable. Build correctness must not depend on it.

### D. Separate Writable Upper Filesystem — Rejected

An overlayfs upper device avoids base capacity limits, but introduces a second
persistent rootfs, whiteout/opaque/xattr semantics, flattening or a new image
format, save/restore changes, and another device lifecycle.

**Decision:** disproportionate to the measured problem and contrary to the
unified single-index disk model.

## Recommended Design

### 1. One Automatic Capacity Policy

The v1 policy is one idempotent absolute target:

```text
automatic_target = max(parent_logical_size, 16 GiB)
```

The value is chunk aligned and is both the default and the automatic-growth
cap. The parent descriptor is validated before the calculation; no unchecked
addition or multiplication is involved. Linux remains the authority on
whether a particular ext4 layout can grow to the visible device geometry, and
a failure leaves the parent and destination ref unchanged.

Policy behavior:

- a compact 512 MiB or 10 GiB image grows once to 16 GiB;
- a child/checkpoint already at 16 GiB stays there;
- an existing 17 GiB, 32 GiB, or larger image keeps its exact size;
- no build request can shrink or explicitly enlarge a rootfs; and
- applying the policy repeatedly anywhere in an image lineage returns the
  same size after the first normalization.

There is no recursive doubling, `parent + headroom` rule, hidden
`--disk-grow-target`, or public build `--disk-size`. Negative controls and
isolated-cache measurements live only in the engineering harness and are
always reported separately from default-path performance. The harness's
`--default-path --idle-ms 0` mode omits `--debug` and experiment controls;
instrumented modes collect WRITE_ZEROES/preparation counters and are reported
as such. Supporting capacity above 16 GiB first requires separately reviewed
index-limit/format work; adding a no-op or unsafe knob now would create a
footgun rather than an escape hatch.

There is no inode option. Online ext4 growth preserves the filesystem's inode
density and adds inode tables with new groups. The workload corpus must verify
that native and external images have adequate density. A pathological imported
filesystem that exhausts inodes fails terminally and must be recreated or
replaced with an image whose filesystem geometry suits that workload; that
rare case does not justify a normal-user knob.

### 2. Grow The Chunk Disk With Clean Known Zeros

Add a growth primitive whose semantic input is an immutable parent index plus
a larger exact logical size:

- `ftruncate` the private sparse backing to the target;
- extend source and optional digest maps with `.zero`, not `.zero_dirty`;
- extend the parent-baseline digest table with null zero entries;
- preserve all parent digest references unchanged; and
- let snapshot encoding reuse untouched appended zeros directly.

`.zero_dirty` remains necessary when an operation changes previously nonzero
parent bytes to zero. Snapshot encoding emits that child zero coverage directly
without reading the chunk, then installs it as the new clean baseline. Tests
must distinguish clean reuse from dirty parent replacement explicitly.

Add `ChunkMappedDisk.zeroRange(offset, len)` for block-device zero semantics:

- validate the entire range before mutation;
- leave any already-zero full or partial range clean;
- mark a full nonzero chunk zero-dirty without writing payload bytes;
- read-modify-write only boundary chunks that contain other nonzero bytes;
- preserve lazy CAS verification before a partial old chunk is changed; and
- reject overflow, out-of-range, read-only, or unsupported requests before
  changing any chunk.

This primitive is the differentiated core: a 256 MiB inode-table zeroout over
new capacity should collapse to validated zero-map operations, not 256 MiB of
overlay writes or an 8 GiB later scan.

### 3. Advertise And Implement virtio-blk `WRITE_ZEROES`

The feature is enabled only for non-resumable rootfs-growth sessions. The build
executor adopts it first; `spore run --commit --disk-size` converges on the
same primitive before release. A savable general-purpose VM continues to use
its current negotiated feature surface. This keeps the change out of portable
saved-machine state while using one shared backend-neutral implementation.

That boundary needs enforcement, not convention. Mark every machine/device
profile that offers the feature non-resumable and make both HVF and KVM
full-machine capture reject it. Rootfs-only build checkpoints remain allowed.
A test must prove no transport state containing the growth-only bit can be
serialized. Put the rejection in the full portable
`takeSnapshot`/serialization path, not in shared transport capture used to
prove virtio queue quiescence for rootfs-only checkpoints.

Implement the Virtio 1.2 block contract narrowly:

- advertise `VIRTIO_BLK_F_WRITE_ZEROES`, one segment, and a nonzero bounded
  `max_write_zeroes_sectors` of 4 MiB per request;
- accept requests only when the feature was negotiated;
- advertise `write_zeroes_may_unmap` because a chunk-map transition is a valid
  zero/unmap implementation; accept the standard UNMAP bit and reject every
  reserved flag bit;
- accept bytes 4..8 as the bounded, ignored historical Linux `ioprio` hint
  (Virtio 1.2 renamed it `reserved` but the pinned driver still populates it),
  require the unused command-level sector to be zero, and validate descriptor
  direction, exact element size, segment count, nonzero sector count,
  multiplication/addition overflow, capacity bounds, and backend writability
  for the complete request before mutation;
- dispatch every validated element through `zeroRange`; and
- preserve existing flush/error/status behavior.

The branch-base transport stored driver feature writes without masking them to
the offered set, and block handlers could not see what was negotiated. Slice 2:

- reject or clear `FEATURES_OK` when the driver-selected set is not a subset of
  offered features;
- validate restored `driver_features` against
  `device_features | VIRTIO_F_VERSION_1` offered by the reconstructed device;
- pass the accepted feature set to device request handling; and
- return unsupported for `WRITE_ZEROES` unless bit 14 was actually accepted.

These transport fixes apply generically; offering bit 14 remains limited to
non-resumable rootfs-growth sessions.

The request parser is guest-controlled security-boundary code. Existing IN/OUT
handlers already prevalidate descriptor directions, lengths, arithmetic, and
capacity before payload mutation, but they are not a transactional template:
the common header accepts at least 16 bytes and ignores the legacy
`ioprio`/reserved field, GET_ID
mutates descriptor-by-descriptor, backend writes can fail after earlier
mutations, and the current fuzz target is crash-oriented. `WRITE_ZEROES`
deliberately sets a stricter boundary: one advertised segment, an exact
16-byte header and exact 16-byte range, with every structural, negotiation,
and range check completed before mutation. Rejection at that boundary leaves
the head byte-for-byte unchanged.

Unit tests plus a stateful semantic fuzz target land in the same slice. The
fuzzer snapshots backend bytes/source states before each generated request and
asserts that rejected requests leave them identical; successful requests must
read back exact zeroes only inside the validated range. Malformed requests
return I/O error or unsupported status without partial mutation.

Do not promise transactional host I/O after a valid request begins: a boundary
chunk `pread`/`pwrite` can still fail after an earlier mutation. Any backend I/O
failure poisons the ephemeral build session, discards the entire unpublished
head, and publishes no `PREPARE`, Dockerfile step record, or destination ref.
Fault-injection tests prove that authoritative parent/cache/ref state remains
unchanged.

### 4. Resize Through The Trusted Initrd Agent

The fixed control request `spore-rootfs-grow-v1` is a strict two-member JSON
object containing exactly one type and one nonempty bounded session identifier.
Missing, duplicate, unknown, over-limit, trailing, and embedded-NUL input is
rejected. It carries no capacity argument or shell text; the exact target is
already the virtio-blk capacity selected and validated by the host. The
grow-only parser is isolated from future fields added to the generic request
path.

The initrd agent:

1. opens `/mnt/rootfs` and `/dev/vda`, outside the selected image's chroot;
2. gets the exact visible device bytes with `BLKGETSIZE64` and decodes the
   feature-aware primary ext4 superblock at byte 1,024;
3. rejects shrink, overflow, or device bytes not divisible by filesystem block
   size;
4. computes the target filesystem block count and calls
   `EXT4_IOC_RESIZE_FS` directly;
5. after `syncfs`, decodes the superblock again and requires the filesystem
   block count to increase, remain at or below the target, and fall short by
   less than one unchanged ext4 block group. This permits bigalloc rounding or
   omission of an unusably small terminal group without accepting a no-op or
   an unbounded or multi-group partial resize;
6. treats `statfs` only as diagnostics, requiring usable blocks no greater than
   the authoritative post-resize block count plus aligned/bounded free bytes
   and valid inode counts; and
7. returns the pre/post filesystem counts, blocks per group, device bytes,
   target and usable blocks, free bytes, and total/free inodes in one exact
   bounded line.

P0 validates the internal mount option for rootfs-growth sessions. The v1
choice is `noinit_itable`, which makes new checksum-enabled groups
perform their inode-table initialization synchronously instead of leaving
`ext4lazyinit` to dirty the disk after `PREPARE`. This is managed initrd policy,
not a user option. The agent must not report preparation success while a
background inode-table initializer can still mutate the rootfs.

The host treats nonzero exit, malformed response, geometry mismatch, VM exit,
or timeout as preparation failure. It never trusts a guest-supplied target.
No Dockerfile step runs and no cache/ref is published.

This removes the selected rootfs's `/bin/sh` and `resize2fs` requirements. It
still deliberately leans on the pinned guest kernel for ext4 correctness.

### 5. Prepared-Base Reuse

Capacity preparation is distinct from Dockerfile instruction caching.
Implementation reuses the existing bounded build step-record parser, atomic
publication, completeness validation, and GC inspection rather than creating a
second prepared-cache directory or record family. Add a typed synthetic
`prepare` member to `StepInput.Operation`; do not fabricate a Dockerfile AST
instruction. Its record fields are canonical and explicit:

```text
instruction_kind = "PREPARE"
StepInput.canonical_instruction = "PREPARE"
StepRecord.instruction = "PREPARE"
operation = prepare { exact_target, producer_identity }
```

The fixed string satisfies the existing mandatory display/record field and is
never parsed as user Dockerfile syntax. Authoritative target and producer
identity are separately typed, hashed, serialized, and validated; they are not
smuggled through `canonical_instruction`, `input_digest`, or the removed
`disk_grow_target` field. New record fields may remain optional only so older
record schemas parse conservatively; a v7 `PREPARE` hit requires both.

For a Dockerfile with at least one executor-backed instruction:

1. Resolve the exact automatic/explicit target from the immutable base.
2. If the base is already at that target or larger, use it directly.
3. Otherwise compute a synthetic step key from:

   ```text
   H(builder_version,
     platform,
     parent_index_digest,
     "PREPARE",
     exact_target,
     guest_kernel_and_initrd_identity,
     block_and_resize_protocol_version)
   ```

4. Read this one infrastructure record even under `--no-cache`. On a validated
   hit, use its prepared child index as the normal Dockerfile cache parent.
5. On a miss, acquire the existing rootfs cache publication lock, recheck,
   boot the ephemeral executor, grow/resize, freeze, quiesce virtio-blk,
   seal only changed metadata chunks, enumerate and encode the canonical
   logical index, publish objects/index/completeness, and write the ordinary
   typed step record last.
6. Continue the same build session from the published snapshot baseline when
   uncached steps remain.

The record contains the exact child `RootfsStorage`, parent digest, target,
platform, and preparation version. It does not contain trusted replacement
geometry. Existing step-record loading revalidates the key, fields,
descriptor-selected index, and completeness stamp.

The `PREPARE` record is already a rootfs CAS GC root under the step-record
model. No new parser, GC namespace, object namespace, flat image, or filesystem
cache is introduced. A missing record is a miss. A malformed record or one
naming incomplete/corrupt storage fails closed and is never silently repaired
in place.

`--no-cache` continues to bypass Dockerfile step-cache reads only. It does not
discard imported OCI materialization or prepared-base normalization. Benchmark
reports label isolated-preparation-cache runs separately when measuring the
normalizer itself.

This carve-out also stabilizes local cache behavior: a repeated `--no-cache`
build consumes the existing `PREPARE` result rather than recomputing and
atomically replacing the parent-to-child mapping with another valid
kernel-produced index. Replacement would remain content-safe, but would waste
work and cascade a new child digest through downstream step keys. The prepared
child remains rooted even if a later Dockerfile RUN fails. Measuring a true
preparation miss therefore requires an isolated preparation/step cache.

### 6. Cache And Identity

- The prepared rootfs identity is the BLAKE3 digest of its exact canonical
  disk index, as today. "Deterministic identity" means the same exact index
  bytes always have the same identity; it does not promise that repeated guest
  execution after a cache wipe reproduces mount timestamps or the same index.
- The synthetic prepare key includes exact target and pinned guest/runtime
  producer identity. Kernel/initrd changes cannot alias an old preparation.
- The source image config is unchanged by preparation. A final image identity
  still combines the exact final rootfs index with canonical config.
- Dockerfile step keys after normalization use the prepared parent index and
  the same exact executor kernel/initrd identity. Two producer versions that
  happen to create the same prepared bytes therefore cannot share RUN/COPY/
  WORKDIR results. Remove `disk_grow_target` from new step input/record
  identity and bump the build cache version from `sporevm-build-v6` to
  `sporevm-build-v7`.
- Concurrent preparation of the same key is serialized by cache publication
  locking. Objects and canonical index publish before completeness; the
  `PREPARE` step record publishes last.
- Repeat preparation in isolated caches must be measured for exact index
  stability on a pinned kernel/initrd. The canonical child index remains exact
  identity even if two isolated caches produce different valid kernel-managed
  timestamps. Such variance costs cross-cache CAS dedup and later step-cache
  reuse after a lost `PREPARE` record; it is not an identity-integrity failure.
  Normalize only bounded fields when the dedup benefit exceeds the maintenance
  cost. Treat post-`PREPARE` background writes, inconsistent filesystem
  semantics, or backend-dependent file content as design blockers.

### 7. Compatibility And Lifecycle

| Case | Expected behavior |
|---|---|
| Fresh OCI base used by build | Import normally, then transparently normalize on first executor use; preparation is reusable across Dockerfiles. |
| Native-writer rootfs | Kernel resize plus storage zero semantics; no native-layout special case. |
| External-writer rootfs | Same path if it mounts as supported ext4 and the kernel accepts online resize; otherwise fail before steps. |
| Existing small local image | Normalize automatically even when original OCI/tar source is unavailable. |
| Locally committed image | Inherit current geometry; normalize once only if below the selected target. |
| Cached intermediate | Its index is authoritative. A state at or above 16 GiB is not grown again; a smaller state prepares once to 16 GiB. |
| Non-quantized image below the cap | Grow once to exactly 16 GiB. |
| Already-normalized or above-cap image | Preserve a valid source index at its exact size; never double or add automatic headroom. A later dense checkpoint still fails closed if its canonical index exceeds the current format limit. |
| Pulled/index-only rootfs | Verify/open lazily, then prepare from the canonical index like a local rootfs. |
| Metadata-only Dockerfile | No executor or capacity preparation solely for ARG/ENV/CMD metadata. |
| Save/restore | A built image keeps its exact geometry. Never change a disk underneath captured RAM/device state. |
| Image commit | Commit inherits the exact prepared/build geometry; using it as a later base does not reapply the default. |
| Old cache records | Old step records remain conservative GC roots but miss after the cache-version change. Old rootfs indexes remain readable. |

### 8. ENOSPC And Capacity Limits

No finite default makes arbitrary RUN output infinitely scalable. The safe
boundary is generous automatic preparation before execution, then explicit
failure rather than replay.

- The fixed growth response includes authoritative pre/post ext4 block counts,
  the block-group bound, and bounded `statfs` diagnostics; the host independently
  validates them before preparation can publish.
- Executor failure retains the real exit status/output. The CLI recognizes the
  common `ENOSPC`/`No space left on device` forms and reports that block or
  inode space was exhausted; it does not relabel every nonzero exit.
- Never retry any instruction automatically, even though COPY might be
  technically replayable; one rule is easier to reason about and avoids
  divergent cache semantics.
- Do not publish the failed step record or destination ref. Earlier complete
  records remain valid.
- There is no automatic retry and no build size knob. The diagnostic tells the
  user to reduce the build footprint or choose an already-larger base. A
  larger automatic/public build capacity is gated on a new checkpoint-safe
  index format or limit, not enabled by bypassing the v1 cap.

### 9. Sparse Allocation And Scaling

Logical capacity must remain cheap but is not literally free:

- sparse `ftruncate` creates no zero payload;
- clean zero-map entries create no CAS objects;
- `WRITE_ZEROES` over already-zero chunks creates no overlay payload;
- ext4 superblocks, group descriptors, and bitmaps create bounded nonzero
  metadata chunks;
- zero inode tables remain logical zeros; and
- current `spore-disk-index-v1` and in-memory maps still have one entry per
  64 KiB logical chunk.

The automatic cap protects index size, map RSS, canonical JSON limits, startup,
and checkpoint time—not physical zero storage alone. Range-compressed zero
coverage remains a separate disk-index format proposal and is not required if
P4 shows a fully nonzero index at the selected quantum and cap fits current
bounds with measured headroom.

One bound is already hard: `disk_index.max_index_bytes` is 64 MiB. A 64 GiB
disk has 1,048,576 logical 64 KiB chunks. An almost-all-zero index may fit, but
a substantially nonzero index carries a digest string/object entry per chunk
and can exceed 64 MiB well before the filesystem reaches ENOSPC. P4 must model
and encode representative nonzero densities, not only an empty grown disk. The
v1 automatic cap must not invite a supported workload into an unencodable
snapshot. Arbitrary COPY/RUN can make every chunk nonzero, so a hidden
sub-100% density envelope is itself a footgun. Choose a cap whose fully nonzero
canonical index fits with RSS/headroom, or make a separately reviewed index
format/limit change prerequisite for larger capacities. Under the current
limit, 16 GiB dense is about 33.39 MiB while 32 GiB dense is about 66.89 MiB
and already fails; 32/64 GiB remain experiments rather than product caps.

## Security And Device Model

- The device remains virtio-blk in the frozen device ordering. No new device
  kind, backend-specific register, or manifest rootfs type is introduced.
- `WRITE_ZEROES` lives in shared backend-neutral virtio code; identical HVF/KVM
  runtime behavior remains a release gate. The offer is restricted to
  non-resumable rootfs-growth VMs so new
  negotiated feature bits do not enter saved machine state. HVF/KVM capture
  reject the ephemeral build profile rather than relying on call-site
  convention.
- Virtio feature selection and restored transport state must be subsets of the
  currently offered features, and request handlers receive the accepted set.
- The new virtqueue request is attacker-controlled. Parser bounds, complete
  rejection prevalidation, unpublished-head discard after backend failure,
  lazy-CAS verification, and stateful before/after semantic fuzzing are release
  requirements, not follow-up hardening.
- The guest-supplied resize response parser is attacker-influenced and has an
  exact field order, pre/post/block-group arithmetic checks, a 1,024-byte limit,
  and fuzz/unit coverage. The host-generated request carries no capacity
  authority.
- The guest rootfs can contain malicious ext4 metadata. The pinned kernel owns
  filesystem validation; the initrd adds only a fuzzed fixed-offset decoder for
  the already-mounted primary superblock's magic, feature-aware 64-bit block
  count, block size, and blocks-per-group post-condition. A kernel, decode, or
  geometry error aborts preparation.
- CAS/index loading remains canonical, digest-checked, completeness-gated, and
  descriptor-authoritative. Host-local cache metadata cannot override it.
- The rootfs cache lock spans preparation snapshot, completeness publication,
  `PREPARE` record publication, and any destination ref update that makes the
  result reachable.

## Experiment Evidence And Remaining Corpus

P0-P4 were used as stop/go experiments before the behavior switch. Their
results are recorded here so the implementation remains traceable. P5 and the
remaining KVM error-path/performance-gate work are release validation rather
than unbounded design work.

### P0. Verify Kernel Zeroing And Lazy-Init Timing First

**Result: positive path passed on HVF and KVM.** Native type-13/UNMAP, HVF
forced fallback, checksum `noinit_itable`, and checksum-lazy negative-control
results are summarized in Current Progress. The positive paths quiesced; the
lazy negative control did not publish. The KVM backend-failure control reached
the intended growth error but exposed a pre-existing double cleanup during VM
teardown, so KVM failure-path validation remains blocked until that is fixed.

This was the first stop/go gate before production Slice 1 or Slice 2 code. It
observed the managed Linux 6.1.155 guest rather than inferring behavior only
from source.

The pinned source already establishes the native expectation:
[`setup_new_flex_group_blocks`](https://github.com/gregkh/linux/blob/v6.1.155/fs/ext4/resize.c#L619-L630)
calls `sb_issue_zeroout` for `EXT4_BG_INODE_ZEROED`, and the
[no-group-checksum path](https://github.com/gregkh/linux/blob/v6.1.155/fs/ext4/resize.c#L1673-L1680)
always sets that flag for new groups. P0 tests feature negotiation, queue
limits, device status, fallback behavior, and external-layout policy; it does
not reopen whether the native ext4 algorithm uses the block-layer zeroout API.
The pinned virtio-blk driver maps successful block-layer zeroout to request
[type 13 with UNMAP](https://github.com/gregkh/linux/blob/v6.1.155/drivers/block/virtio_blk.c#L239-L242);
telemetry must distinguish that path from the block layer's ordinary-write
fallback.

For native and checksum/uninitialized-group external fixtures, record:

- whether online resize submits virtio request type 13 or ordinary OUT writes;
- whether request type 13 carries the standard UNMAP bit;
- whether every type-13 request completes successfully without the block layer
  silently retrying bulk zero-page OUT writes;
- synchronous inode-table zero bytes versus journal/bitmap metadata writes;
- whether `ext4lazyinit` starts or remains active after the resize response;
- writes that occur before, during, and after the preparation freeze/snapshot;
  and
- behavior when the ephemeral build rootfs is mounted with internal
  `noinit_itable` rather than the normal writable mount options.

The intended v1 contract must reach a quiescent filesystem before publishing
`PREPARE`. If `noinit_itable` safely makes all new-group inode-table work
synchronous, use that internal growth-session mount option and verify the zeroes
arrive through request type 13. If supported external layouts still leave
background initialization or mostly ordinary bulk writes, stop and compare
the CAS-native grower or capacity-at-birth fallback before implementing the
full virtio path.

### P1. Split Current Cost And Prove Clean-Zero Growth

**Result: passed.** Appended capacity changed the checkpoint from 3,376 ms and
131,073 sealed chunks to 7 ms, one sealed metadata chunk, and zero scan time.

Add structured timings/counters for:

- map allocation and sparse `ftruncate`;
- guest boot-to-resize request;
- resize operation;
- virtio request types, bytes, and ranges;
- freeze/quiesce;
- dirty, zero-dirty, reused, and sealed chunk counts;
- zero-scan/hash/object-write time; and
- canonical index encode/write/completeness time.

Run compact default growth, compact growth with appended sources treated as
clean zero, and pre-grown 10 GiB. The clean-zero variant must not seal or scan
work proportional to the appended 8 GiB tail.

### P2. Prototype `WRITE_ZEROES` Plus Direct Ioctl

**Result: passed on HVF.** The prototype became the product path. Growth does
not invoke the selected rootfs shell, the no-`resize2fs` smoke passes, and the
managed initrd sends the fixed request before Linux issues the ioctl.

In an experiment-only branch:

- advertise one write-zeroes segment;
- implement checked `zeroRange`;
- call `EXT4_IOC_RESIZE_FS` from the initrd agent; and
- remove the `resize2fs` process from the experiment path.

Use the P0-selected build mount behavior. Confirm that request type 13 reaches
the chunk backend, that ordinary journal/bitmap writes remain bounded metadata,
and that no lazy-init writer remains after the preparation checkpoint.

For 512 MiB -> 8.5/10/16 GiB, record request count, logical zeroed bytes,
overlay bytes, changed chunks, unique CAS bytes, resize time, and total build
time. Assemble once and require `e2fsck -fn`, successful boot, correct
`statfs`, and writes beyond the old boundary.

### P3. Quantify Preparation Variance And Prove Prepared Reuse

**Result: passed on HVF; KVM preparation passes but the overall KVM gate remains
open.** Five isolated ReleaseSafe runs are stable at 362 ms
cold median, 126 ms preparation-publication median, 127 ms preparation p95,
and 166.1 MiB median peak RSS. Five uninstrumented equivalent-fixture runs from
the same exact parent have a 0.44s cold median/p95 and produced the same
prepared index, key, and producer identity. Shared `PREPARE` reuse works under
`--no-cache` while skipping resize/checkpoint work. On KVM, five instrumented
samples had 529 ms median / 532 ms p95 total time and 211 ms median / 218 ms
p95 preparation-publication time; a same-parent follow-up produced identical
PREPARE derivation identity in all five samples. The KVM two-RUN harness has no
same-host prepared/no-growth baseline, and its functional warm/incremental
paths were not timed, so those KVM performance gates remain open. The
failure-path teardown bug also prevents an overall KVM pass.

Repeat the same parent/target preparation at least five times with isolated
caches on one pinned kernel/initrd, then on HVF and KVM using the identical
guest artifacts.

- Compare canonical index digest and changed chunk digests.
- If they differ, identify exact bytes and classify them as bounded
  kernel-managed metadata, ongoing lazy-init activity, or semantic filesystem
  differences. Quantify lost dedup/cache reuse; do not make timestamps alone a
  correctness failure.
- Measure a preparation-record hit, miss, extra pre-step checkpoint, GC root,
  and two unrelated Dockerfiles sharing the same base.
- Include repeated `--no-cache` builds.

Prove that the one-boot pre-step checkpoint stays inside the cold-build gate
and that a `PREPARE` hit avoids resize/checkpoint work under `--no-cache`.

### P4. Select Default Capacity And Cap

**Result: the format gate selected 16 GiB for v1.** Dense 16 GiB fits with
47.8% headroom; dense 32 GiB fails the current format limit. Large COPY and
representative native/checksum fixtures pass. The wider distro, large-RUN,
and inode-exhaustion corpus remains release/next-slice evidence, not a reason
to expose a larger unsafe target.

Measure 10, 16, 32, and 64 GiB targets for native Alpine, Debian/Ubuntu, and
at least one large external-writer image. Record:

- grow and total cold time;
- peak RSS and map allocation, including `grow()` temporarily duplicating
  source, CAS-digest, parent-digest, and populated digest-string storage before
  releasing the old tables;
- index bytes and zero-entry count;
- canonical index bytes at 0%, 25%, 50%, and 100% nonzero-chunk density,
  including the exact 64 MiB encode/parse failure threshold;
- unique CAS object bytes/count;
- sparse flat logical versus physical bytes;
- runtime disk-open and first snapshot latency;
- free blocks/inodes and inode density; and
- behavior crossing the native profile's 16 GiB descriptor-block boundary.

Exercise Alpine package install, apt, Node, Ruby bundle, the current
`buildkite-sporevm` workload, a large COPY, a large RUN-generated output, and
an empty-file inode-exhaustion workload. Confirm or replace the candidate
16 GiB quantum and select a checkpoint-safe cap from this corpus.

### P5. Compatibility And Failure Corpus

**Status: in progress.** Unit/fuzz/cache-GC/backend-failure, existing-small,
basic run-commit, generic save/restore and bundle, and HVF build-smoke coverage
is present. Native KVM now covers build/run, a 2.25 GiB sparse COPY, the
run-commit lifecycle including save/fork/restore, and local pull. That
run-commit smoke does not save or restore an actual `spore build` prepared
output, so prepared-output lifecycle coverage remains open. Its injected
growth failure is blocked by the teardown crash described above. An additional
generic writable-rootfs smoke stopped at a pre-existing assertion for legacy
layered manifests before its lifecycle checks; it is not counted as KVM
capacity evidence. Exploratory HVF runs completed a verified 512 MiB
RUN-generated file in 5.00s and observed the intended
terminal/no-retry/unchanged-ref behavior for both block and inode ENOSPC. The
wider distro/workload corpus and reproducible retained large-RUN plus
block/inode exhaustion smokes remain.

Cover:

- native and external rootfs writers;
- full and partial final ext4 groups;
- existing compact images and source-less commits;
- a cached intermediate below and at the target;
- corrupt/missing parent chunks and synthetic `PREPARE` records;
- unsupported/dirty ext4 states;
- ioctl timeout/error and malformed write-zeroes requests;
- concurrent preparation and injected failure at each publication boundary;
- ENOSPC for blocks and inodes; and
- a large existing image above the automatic cap.

## Decision Gates

P0/P1 justified implementing Design A on the reference M4/HVF host. Linux
ARM64/KVM is now measured, but the branch is not release-complete until its
teardown blocker and unpaired performance gates are resolved and every
still-unmeasured item below is recorded:

- incremental preparation work inside the same already-booted executor session
  (grow/ioctl/pre-step checkpoint/record, excluding the shared build boot) has
  p95 at most 250 ms on each backend, with the median reported rather than
  hidden; HVF measures 126 ms median / 127 ms p95 and KVM measures 211 ms
  median / 218 ms p95, while the user-facing cold-build gate below remains
  authoritative;
- on each backend, tiny cold median is within 150 ms of a paired
  prepared/no-growth baseline using the same host, commit, parent, and fixture;
  the historical 0.36s baseline and preferred result at or below 0.50s are
  reference M4/HVF measurements, not KVM thresholds;
- appended known-zero bytes cause no proportional overlay writes, CAS payload,
  sealed-candidate count, or zero-scan time;
- the fully nonzero canonical index at the selected default/cap fits below
  `max_index_bytes` with measured RSS/headroom, and normal ENOSPC cannot first
  appear as an unencodable snapshot;
- changed/sealed chunks scale with ext4 group metadata rather than logical
  bytes added;
- P3 shows no post-checkpoint background writer or semantic/backend-dependent
  filesystem difference; bounded timestamp-only variance is reported rather
  than treated as a correctness failure;
- all supported ext4 corpus cases are fsck-clean and bootable;
- malformed requests and injected failures leave parent/cache/ref state
  unchanged, the CLI exits through its normal build-error path, and no backend
  teardown abort follows; and
- the warm path remains boot-free on both backends. On reference M4/HVF it is
  at most 0.15s, and the historical one-COPY 0.34s path regresses by no more
  than 20%; the measured values are 0.13s and 0.40s. On KVM, compare warm and
  one-COPY medians with paired pre-grown/no-preparation controls on the same
  host and require no more than 20% regression. Retaining full index/CAS
  validation is preferable to chasing the historical 0.09s HVF warm result by
  weakening cache integrity.

If latency, quiescence, or filesystem semantics fail, prototype the narrow
CAS-native grower for the Spore native profile before expanding device/cache
complexity. Bounded kernel timestamp variance alone is not a fallback trigger.
If compatibility alone fails for a minority external layout, compare
capacity-at-birth for that producer with a clear fail-closed error; do not
silently fall back to a slow guest `resize2fs` process.

## Benchmark And Validation Matrix

Use ReleaseSafe, fixed source/image digests, isolated and shared preparation
caches, isolated Dockerfile caches, successful runnable-output verification,
and at least five tiny samples or three large samples. Always report the fixed
default path separately from engineering-only negative controls. The harness
must set the explicit `SPOREVM_ROOTFS_GROWTH_EXPERIMENTS=1` master opt-in before
any fault or idle control is honored; ordinary builds ignore the individual
control variables when that master opt-in is absent.

| Workload | Cold/no-cache | Prepared/shared | Warm | Incremental/failure proof |
|---|---|---|---|---|
| Tiny Alpine fixture | default and isolated preparation | preparation hit | full step-cache hit | one COPY and trailing RUN change |
| Medium package install | native and external base | repeat same base | cache hit | package-list change, blocks/inodes |
| Large `buildkite-sporevm` | default capacity | shared base | cache hit | one COPY and one RUN change |
| Large COPY | below/near/above capacity | repeat base | cache hit | changed tail; terminal ENOSPC |
| Large RUN output | below/near/above capacity | repeat base | cache hit | changed command; no retry |
| Inode exhaustion | increasing empty files | repeat base | n/a | free-inode diagnostics, unchanged ref |

Required correctness passes:

- canonical index/object validation and completeness;
- `e2fsck -fn` after growth and after representative builds;
- read/write beyond the original filesystem boundary;
- save a VM from a built image, restore it, and preserve exact disk geometry;
- commit a built image and use the commit as a later build base without
  another default grow;
- pack/unpack/pull the resulting rootfs and preserve exact identity;
- identical smoke script and visible behavior on HVF and KVM;
- cache corruption/miss and GC reachability tests;
- concurrency/fault-injection publication tests; and
- fuzz/unit coverage for virtio write-zeroes, zero-range arithmetic, resize
  control parsing, capacity parsing, and existing index/descriptor loading.

## Delivery Strategy

### Slice 0. Instrument And Run The Stop/Go Experiments

**Status: complete on HVF; KVM positive-path repeat complete, with the
error-path blocker and unpaired performance gates remaining in Slice 7.**

- Add P1 phase timings/counters behind existing build profiling.
- Prototype clean-zero growth, one-segment `WRITE_ZEROES`, and direct ioctl in
  test/experiment paths.
- Run P0 first and stop before production storage/device work if negotiation,
  fallback suppression, or external lazy-init policy fails.
- Then run P1-P4 on HVF and a KVM sanity host.
- Replace provisional constants and record prepared-miss/hit results in this
  plan.

This slice made no default behavior or public CLI changes.

### Slice 1. Correct Known-Zero Storage Semantics

**Status: implementation complete.** Shared backend unit/compile coverage and
the HVF runtime smoke pass are complete. Native KVM positive-path runtime is
measured; its error-path blocker remains in Slice 7.

- Add clean-zero disk growth and `zeroRange` to `ChunkMappedDisk`.
- Preserve dirty-zero semantics for clearing parent data.
- Add unit/property tests for full/partial/CAS/read-only/out-of-range cases.
- Pin the mixed-parent growth invariant: old digests remain unchanged, every
  appended null digest is paired with `.zero`, the child index explicitly
  covers the full tail in `zero_chunks`, no tail chunk is sealed, and the
  result equals a full-rescan oracle. Then write one appended chunk and require
  exactly that chunk to seal.
- Expose snapshot counters proving appended zeros are reused without sealing.

This slice is useful independently and does not change the guest device
feature surface.

### Slice 2. Add Growth-Session virtio `WRITE_ZEROES`

**Status: complete.**

- Implement feature/config/request support in shared virtio-blk code.
- Enable it initially only for ephemeral build executor root disks, behind a
  reusable non-resumable rootfs-growth profile.
- Mask/validate selected and restored driver features against the offered set,
  and pass accepted features to device request handling.
- Make full-machine capture reject the ephemeral build feature profile on both
  HVF and KVM.
- Validate every request completely before mutation.
- Add stateful before/after fuzzing, malformed-chain tests, status/error tests,
  and shared HVF/KVM backend coverage. Complete the native KVM failure-path
  rerun in Slice 7.
- Update `SECURITY.md` and the device contract documentation in the same
  change.

This slice made no capacity policy change by itself.

### Slice 3. Replace The Guest Tool With Direct Resize

**Status: implementation complete.** Corruption and GC coverage pass; the
concurrency/publication fault-injection matrix remains in Slice 7.

- Add no-capacity-argument `spore-rootfs-grow-v1` to the initrd agent and host
  executor, with exactly one type and one bounded session identifier.
- Derive target bytes from `BLKGETSIZE64`, validate authoritative pre/post ext4
  block counts with the one-group terminal bound, and return bounded statfs
  diagnostics.
- Bump the PREPARE producer contract so records created under the weaker
  request or post-resize validation rules are deterministic cache misses.
- Replace `resize2fs /dev/vda` on the build path.
- Remove the selected image's `/bin/sh`/e2fsprogs prerequisite and related
  error text/tests.
- During the intermediate branch state, keep build versus
  `run --commit --disk-size` dependency/error text explicit; do not publish a
  release that implies the run path has converged before Slice 6.
- Prove the default tiny path meets the performance gate before proceeding.

The temporary target/cache identity was removed by Slices 4 and 5.

### Slice 4. Install The Stable Capacity Policy

**Status: complete.**

- Replace doubling/additive policy with the measured absolute default.
- Remove hidden `--disk-grow-target` from the CLI.
- Do not add a build size knob: P4 selected the 16 GiB default/cap and showed
  that the next useful quantum is not dense-index safe.
- Add cap, alignment, shrink, overflow, and already-large-image tests.
- Add block/inode ENOSPC diagnostics; never retry steps.

### Slice 5. Add Prepared-Base Reuse

**Status: complete.**

- Add the typed synthetic `prepare` operation to existing step-key/record
  publication. Existing GC inspection already roots any schema-valid complete
  child storage regardless of instruction kind; keep that logic unchanged and
  add a `PREPARE` coverage test.
- Resolve it before Dockerfile step-cache keys; honor it under `--no-cache`.
- Continue an executing VM from the published preparation baseline.
- Reuse step-record GC roots and cover corruption in this slice; defer the
  wider races, fault injection, and concurrent-preparation release matrix to
  Slice 7.
- Remove `disk_grow_target` from new step records and bump the step-cache
  version.

### Slice 6. Converge `spore run --commit --disk-size`

**Status: complete.**

- Move image-commit growth to the same known-zero tail, non-resumable
  growth-session `WRITE_ZEROES`, and `spore-rootfs-grow-v1` agent request.
- Delete its shell/`resize2fs` implementation and share geometry validation,
  statfs diagnostics, failure handling, and tests with build preparation.
- Preserve commit's existing rule that `--disk-size` cannot combine with
  full-machine save, and assert any VM offered the growth-only feature cannot
  enter portable snapshot serialization.

This convergence follows the successful build-path gates; it does not block P0
through Slice 5 experimentation, but it is required before release.

### Slice 7. Cross-Backend, Lifecycle, And Durable Docs

**Status: in progress.** Core HVF growth smokes and documentation are complete.
Native KVM positive paths, the run-commit lifecycle, large COPY, and local pull
pass; its forced-failure teardown blocker and paired cold/warm/incremental
performance measurements remain open, alongside concurrency/publication
injection, prepared-output save/restore/pack/unpack/pull identity, and
committed-image-as-a-later-build-base.

- Run the full benchmark/correctness matrix on HVF and KVM.
- Give the KVM vCPU allocation exactly one cleanup owner, strengthen the
  forced-failure smoke to require CLI exit status 2 and reject signal exits,
  then rerun the affected KVM matrix before release.
- On that KVM host, measure paired default and prepared/no-growth runs of the
  exact historical fixture plus warm and one-COPY incremental samples; do not
  compare absolute KVM time with the historical macOS/HVF baseline, and judge
  the paired deltas against the per-backend gates above.
- Cover commit, save/restore, pack/unpack/pull, old caches, and existing local
  images.
- Update the active `spore-build` plan and durable docs below.
- Add release notes for the cache break, new default/cap, dependency removal,
  and absence of a build-capacity knob in v1.

## Documentation, Security, And Format Impacts

### `docs/plans/spore-build.md`

Replace the current doubling formula, resize process, hidden override, and
guest package requirement with the final automatic target, direct initrd
request, storage-aware zero behavior, typed `PREPARE` record, and measured
results.

### `docs/rootfs.md`

Document automatic build growth, sparse logical versus physical capacity, the
fixed 16 GiB v1 target/cap, inode behavior, existing/local/committed image
handling, prepared-base reuse, and terminal ENOSPC behavior.

### `docs/filesystem.md`

Document clean appended zero semantics, growth-session `WRITE_ZEROES`, direct
kernel resize, exact geometry inheritance, and why zero capacity creates
bounded metadata/index/map overhead rather than payload storage.

### `docs/spore-format.md`

No rootfs or disk-index schema change is required. Synthetic `PREPARE` step
records are host-local cache metadata, not portable restore authority. Exact
grown bytes are already named by the canonical disk index.

Record that the write-zeroes offer is limited to non-resumable rootfs-growth
VMs and is not serialized into a spore. Offering it to savable VMs later
requires a separate negotiated-device-state compatibility review and matching
HVF/KVM restore coverage.

### `SECURITY.md`

Update the `spore build` boundary to cover:

- fixed-shape direct resize rather than arbitrary `resize2fs` execution;
- selected/restored virtio-feature subset validation and propagation of only
  accepted features to request handlers;
- guest-controlled write-zeroes framing, exact request shapes, complete
  rejection prevalidation, and stateful semantic fuzzing;
- enforcement that the growth-only profile cannot enter full-machine save,
  while rootfs-only checkpoint/quiescence capture remains valid;
- clean-zero versus dirty-zero integrity;
- lazy-CAS partial-zero behavior;
- synchronous inode-table initialization, lazy-init exclusion, and filesystem
  quiescence before preparation publication;
- discard of an unpublished head after a valid request encounters backend I/O
  failure;
- `PREPARE` record validation, locking, GC rooting, and publication order;
- fixed capacity policy/cap and ENOSPC diagnostics; and
- required fuzz targets for the new virtqueue and control-request parsers.

### Cache And Release Compatibility

- Bump the build step-cache version when preparation replaces grow-target
  fields.
- Include kernel/initrd/protocol identity in preparation keys.
- Keep old rootfs indexes/images readable.
- Keep old build records conservative GC roots but do not reuse them under new
  key semantics.
- Release notes call out one-time cache misses and removal of the guest
  e2fsprogs requirement.

## Key Learnings From Pressure-Testing

- The current regression is not simply process-launch overhead. SporeVM turns
  storage-known zeros into both guest I/O and later host scanning; both must be
  removed to reach the prepared baseline.
- Managed Linux 6.1.155 synchronously calls the block-layer zeroout API for the
  native profile, but checksum/uninitialized-group layouts can defer work to
  `ext4lazyinit`. Growth sessions therefore use internal `noinit_itable` and
  P0 proves there is no fallback bulk OUT or post-checkpoint writer.
- A host ext4 grower is not the smallest use of SporeVM's architecture. The
  smaller boundary is to let Linux own ext4 and make zero block operations
  first-class in the chunk map.
- Prepared-base reuse does not need a second cache subsystem. A typed synthetic
  operation can reuse the existing step-record parser, publication, and GC
  machinery while remaining readable under `--no-cache`.
- Capacity-at-birth does not solve existing/source-less local images and adds
  user intent/cache variants. It remains an optimization, not the product
  contract.
- Transparent growth must happen before arbitrary RUN. ENOSPC after RUN cannot
  safely trigger a resize/replay loop. Because the next useful quantum is not
  dense-index safe, v1 fails terminally instead of exposing an unsafe build
  size override.
- Restricting the new virtio feature to non-resumable rootfs-growth VMs avoids
  broadening saved-machine compatibility in the first slice.
- Growth-session-only offering still required generic feature-subset
  validation and negotiated-feature plumbing; the branch-base transport stored
  arbitrary driver feature bits and request handlers could not see the
  accepted set.
- Kernel-produced bytes and repeatability are an experiment, not an assumption.
  Exact index identity remains authoritative; bounded timestamp variance is a
  dedup cost, while post-checkpoint mutation or semantic/backend-dependent
  output is a correctness blocker.
- Sparse capacity still consumes index/map/RSS overhead. The cap must be based
  on a fully nonzero index fitting the current 64 MiB bound with headroom, not
  only `du` output or an all-zero growth benchmark.
- Backend failure injection must prove normal process termination as well as
  unchanged publication state. The KVM run printed the intended growth error
  before a pre-existing duplicate vCPU cleanup aborted teardown, demonstrating
  that matching diagnostics alone are insufficient fail-closed evidence.

## Resolved Recommendations

- Use storage-aware kernel resize as the primary design.
- Append capacity as clean known-zero chunks and implement checked zero ranges.
- Add rootfs-growth-session virtio-blk `WRITE_ZEROES` so ext4 zeroout stays
  metadata.
- Make `noinit_itable` the internal growth-session mount policy, subject to P0
  fixture validation, so no lazy inode-table writer survives `PREPARE`.
- Validate selected/restored virtio features against the offered set and pass
  accepted features to request handling.
- Replace the guest `resize2fs` process with a fixed initrd-agent
  `EXT4_IOC_RESIZE_FS` request.
- Require the strict two-member grow request, decode the feature-aware ext4
  superblock pre/post condition in the guest, and validate its reported
  progression and block-group bound on the host.
- Use one idempotent absolute-capacity quantum policy, never recursive
  doubling/additive headroom.
- Configure nothing by default; expose no build capacity override in v1.
- Do not expose inode, headroom, profile, cap, writer, or resize-tool knobs.
- Reuse the existing canonical rootfs CAS/index/publication path.
- Record prepared-base derivations as typed synthetic `PREPARE` step records
  that remain readable under `--no-cache`.
- Use 16 GiB as the v1 target/cap because its fully nonzero canonical index
  fits below the current 64 MiB bound with measured headroom.
- Converge `spore run --commit --disk-size` on the same growth primitive before
  release.
- Keep the CAS-native host grower as the fallback, not a parallel first
  implementation.
- Keep default-path performance results separate from negative-control and
  isolated-preparation-cache experiments.

## Remaining Release Questions

1. After correcting KVM vCPU teardown ownership, does forced growth failure
   return CLI status 2 with unchanged parent/cache/ref state, and do paired
   same-host samples of the exact historical fixture meet the cold, warm, and
   incremental performance gates? Native KVM request shape, quiescence,
   prepared identity, cache reuse, run-commit lifecycle, large COPY, and local
   pull already pass; prepared build-output save/restore remains open.
2. Which additional external-writer ext4 layouts should be declared supported
   after the current native and checksum-enabled fixtures? A layout that the
   pinned kernel cannot online-resize remains a narrow fail-closed
   compatibility case; there is no slow `resize2fs` fallback.
3. If real workloads eventually require more than 16 GiB, should the next
   proposal raise the canonical-index limit or introduce range-compressed
   coverage? That is a format/RSS design prerequisite, not a v1 knob.
