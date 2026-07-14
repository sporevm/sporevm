# Release Notes

## Next

Bounded named exec now has a documented lossless JSON representation for
arbitrary stdout and stderr bytes. Valid UTF-8 remains a JSON string, while an
invalid UTF-8 stream is emitted as an integer byte array; Zig, C, and Go callers
therefore preserve exact output without changing existing valid-text results.

`spore build` now supplies the conventional `HOME=/root` process environment
to root `RUN` steps when the effective HOME is absent or empty. This matches
Docker/BuildKit for tools such as Go that require a cache home. Explicit
non-empty HOME values remain authoritative; `ENV HOME=` remains empty in the
published OCI config while root `RUN` receives `/root`. ENV and ARG follow
Dockerfile instruction order for build execution without publishing ARG.
Affected RUN cache keys include the effective value, so records produced by the
older environment contract miss safely; HOME normalization does not affect
COPY or WORKDIR identities. Stages without PATH also receive and publish
BuildKit's conventional Linux PATH, including `FROM scratch`. Explicit PATH
values remain authoritative in the published config, while later ARG values
affect only subsequent build-time state according to Dockerfile instruction
order.
The stage PATH participates in RUN, COPY, and WORKDIR cache identities, so older
records created without it miss safely. Build help also lists the existing
memory, vCPU, timeout, and `nofile` controls, and missing Dockerfiles, contexts,
or base inputs receive a concrete diagnostic instead of a bare `FileNotFound`.

Named persistent restore now uses the same proof-gated local RAM backing as
one-shot `spore run --from` and attach. Restore selection is centralized across
KVM and HVF, and the plan owns the backing fd until the private mapping has been
created. Optional missing, stale, foreign, non-regular, or mismatched backing
inputs still fall back to verified chunks, while malformed authoritative
metadata, allocation failure, unexpected I/O, corruption, and backend or
platform failures remain errors.

Named monitor timing now separates backend RAM, machine-state, and pre-run
restore work from vsock request delivery, connect, guest response, and ready
publication. The named-restore benchmark consumes those structured fields, so
a proof fallback cannot be mistaken for a slow guest readiness handshake.

Linux proof creation now measures existing fs-verity state before changing
permissions. New owned read-only backings temporarily regain owner-write only
for enablement, then restore their exact mode and stable device, inode, owner,
and size before a schema-v2 proof can be published. The proof binds the
post-enable mtime and digest after an exact re-stat; failure leaves chunks
authoritative.

Named monitors now advance host-side vsock ports from a random per-process
offset for readiness and every control stream. Completing a stream also drops
queued packets for its old four-tuple before the next attach, preventing stale
credit or control traffic from crossing into a repeated named exec.
Multi-vCPU HVF and KVM now dispatch completed hypervisor exits before handling
concurrent network wakes, so virtio MMIO operations cannot be dropped and
re-executed while the guest is inside an interrupt handler. After multi-vCPU
HVF delivers a host vsock request and raises its SPI, it exits the running vCPUs
once so an idle guest observes the interrupt promptly; empty polls do not wake.
Multi-vCPU HVF capture and restore also use one shared virtual-counter authority
for every vCPU. Per-vCPU timer deadlines are translated into that counter domain
with wrapping arithmetic, preventing cross-CPU time skew from surfacing as RCU
stalls after restore while preserving enabled, masked, and expired timers.

Named lifecycle console paths are now optional and truthful. Ready, list,
result, and failure output report a path only when `--console-log` is configured,
and restore ignores console paths embedded in saved lifecycle metadata so
an input spore cannot select or truncate an arbitrary host file.

The named-restore release harness pins v0.12.0 archives and managed-kernel
assets by digest and requires an exact clean current commit on Linux ARM64/KVM
and macOS ARM64/HVF. Its five-row matrix separates correctness from
performance, covers one- and two-vCPU local backing plus deliberate eager
fallback, requires zero reported
RAM materialization on every valid local-backing row, and retains the measured
eager materialization cost. It also records proof-write and validation timing,
fan-out validation, Linux fs-verity v2, tmpfs v1, cross-filesystem fallback,
and signal-safe named cleanup in a path-sanitized evidence artifact. The Linux
release lane ignores the general benchmark scratch and requires a dedicated
host-provisioned ext4 path that passes an fs-verity enable-and-measure
preflight before parent capture.

Fork now retains the proven parent backing fd across child creation and checks
each opened child hardlink against the proof-bound parent file identity before
writing a child proof. Path replacement, identity mismatch, and unexpected I/O
remove the link and fail closed. KVM and HVF continue to map every child with
`MAP_PRIVATE`, so parent and sibling writes remain isolated.

The additive saved-spore removal Zig/C/Go API raises the libspore C ABI version
to 15. Clients can compare
`spore_build_info(SPORE_BUILD_INFO_ABI_VERSION, ...)` with `SPORE_ABI_VERSION`
before using `spore_remove_saved_json`.

`spore rm --spore DIR` now removes valid diskless single- and multi-vCPU saves
as well as disk-backed saves. Text and JSON results distinguish the diskless
case instead of inventing a pin identity; the existing disk-backed
validate-delete-sync-unpin ordering is unchanged.

Writable-disk saves now reference the machine's global rootfs CAS through an
opaque durable pin in host-private lifecycle metadata. In the cache-backed
steady state, where the parent is already in the global CAS, saves no longer
hardlink or copy every unchanged parent object, remain valid after directory moves, and
survive rootfs GC and destructive prune. Raw moves are supported, but raw copies
share one pin identity and are not independently removable; removing one may
invalidate the others. Use fork for an independent machine-local lifecycle or
pack/unpack for portability. Raw deletion safely leaks a pin. `spore cache pins` lists IDs and
canonical-index health but does not detect orphans; expert-only
`spore cache unpin PIN_ID --force` removes a known ID with an explicit warning.
This pre-1.0 contract adds no global reference registry. `spore pack` still
copies and verifies every required index and object into a self-contained
portable bundle.

Indexed unpack and pull now retain descriptor-bound chunked rootfs authority
inside the output spore while populating the selected host cache from the same
verified object reads. A fresh host can reinstall that local CAS into an empty
cache; an exact index-valid, complete host cache remains the trusted warm-open
path. `spore pack` continues to deep-verify a present local rootfs CAS, so host
cache state cannot mask loss of the spore's claimed self-containment.

On exact-head KVM and HVF runs using the pinned Node arm64 base, the first save
after portable restore migrated 2,621 verified objects / 171,769,856 bytes and
all four later saves migrated zero. KVM measured a 4,688 ms first-migration
source pause versus 4,562–4,566 ms steady; HVF measured 2,808 ms versus
2,029–2,044 ms. The independent empty-cache product pack, fresh named restore,
five-save sequence, and public saved-spore cleanup all completed on both
backends. These results are separate from the earlier augmented dense 1 GiB
same-/cross-filesystem export fixture.

Offline pinned-disk fork results now report cache-lock wait separately from the
lock-held pin and batch publication interval in human output, JSON, and
`libspore.ForkResult`.

Save publication durably orders writable-disk objects, the canonical index,
and its completeness stamp before publishing the pin and save. A named VM can
therefore continue after its first save is removed and collected, publish a
second save, restore it, and fast-fork the restored VM from that exact new
baseline. The continuing VM's active lease and durable registry spec move to
that baseline before the old lease is released, so a failed handoff retains the
old authority instead of persisting a split view.

Named saves now acquire the global cache lock before pausing vCPUs. A contended
save remains pending while the guest runs, reports the accumulated lock wait
separately, and starts its measured source-pause interval only after acquiring
the lock that spans capture and durable publication.

Offline fork output remains batch-owned: children share RAM chunks through
batch-relative `../shared-chunks` links. The complete batch may be moved, but
an individual child directory is not independently movable; pack/unpack is the
portable per-child boundary.

`spore fork --vm` now fast-forks disk-backed named VMs with one writable rootfs
device. The source monitor pauses once, drains virtio-blk, captures shared
RAM/machine state, and prepares up to 32 independent disk heads from the same
epoch without sealing dirty disk state. APFS clone and Linux `FICLONE` are the
default path when the live head has physical overrides; native-clone failure is
closed unless the caller explicitly uses `--allow-slow-copy`. When a successful
save has committed the exact canonical baseline and no later overrides exist,
children receive fresh sparse heads without a filesystem clone or slow-copy.
The `sparse` clone method is private runtime descriptor metadata, not a durable
spore-format change. Networked named fork remains unsupported.

Fork children claim their unlinked overlay fd through a random, one-use,
child-bound local token and do not publish readiness until they have reopened
the immutable baseline and adopted the disk head. Durable baseline leases keep
live children valid after source removal and destructive cache GC/prune, and
children can fork again or save/restore normally. `spore --json fork` and
`libspore.NamedForkResult` report RAM capture, disk preparation, source pause,
and child readiness phases separately. Monitor-generated guest session IDs now
include a per-process random nonce, preventing a restored or forked guest from
replaying a source monitor's cached first exec response.
Writable overlays and lazy sparse rootfs bases now follow absolute `TMPDIR`,
so Linux hosts can place the fast-fork path on reflink-capable scratch storage;
child adoption rejects a head from a different filesystem before readiness.

`spore build` now prepares small root filesystems to a fixed sparse 16 GiB
capacity without recursive growth or user tuning. The host appends known-zero
chunks, a transient growth VM negotiates virtio-blk `WRITE_ZEROES`, and the
managed initrd calls `EXT4_IOC_RESIZE_FS` directly; capacity preparation no
longer invokes the selected image's shell or needs e2fsprogs/`resize2fs`.
Builder-v7 stores this normalization as a typed `PREPARE` derivation, so
unrelated Dockerfiles and `--no-cache`
builds reuse it while ordinary Dockerfile cache semantics remain unchanged.
RUN/COPY/WORKDIR keys bind the same exact executor kernel/initrd identity.
Managed-default cache hits avoid kernel/initrd body reads; a miss verifies and
boots the same once-opened kernel bytes, while explicit overrides are eagerly
retained. This prevents cross-producer cache reuse or artifact-path races after
a PREPARE hit.
Old build records miss once but remain conservative GC roots; old rootfs
indexes and local images stay readable. There is no build capacity knob in
this version: 16 GiB is both the automatic target and cap because the next
useful quantum is not safe for a fully dense index under the current 64 MiB
canonical-index limit.

`spore build` now supports ordinary multi-stage Dockerfiles with named and
numeric earlier-stage references, target pruning, `scratch`, public/local/OCI
bases, named OCI-layout build contexts, OCI config inheritance, and literal
`COPY --from`. Immutable source stages are attached as bounded read-only
virtio-blk inputs, and cache keys bind the exact source index plus the exact
kernel, initrd, and embedded build-agent identity. Cross-stage COPY preserves
modes, ownership, mtimes, symlinks, hardlinks within each source tree, and regular-file
`security.capability`; every other visible `security.*` xattr fails closed.
Mounted RUN, heredocs, exec-form RUN, advanced COPY flags, and non-root build
execution remain unsupported.

Automatic growth is limited to SporeVM's journal-less native and e2fsprogs
ext4 profiles, or equivalent layouts accepted by the pinned guest kernel.
Before the first writable mount, the managed initrd rejects journal presence,
recovery/error/orphan state, and pending orphan cleanup. Unsupported small
sources remain readable but fail growth before a build step, image, or mutable
destination ref is published. After mount, the agent repeats the same source
state validation before the resize ioctl and after the resized filesystem is
synced.

`spore run --image SOURCE --commit local/name:tag -- COMMAND` can now publish a
successful one-shot run's writable root disk as an indexed local image. The
commit path freezes the guest filesystem, reuses the quiesced rootfs snapshot
and CAS machinery, preserves source OCI config, permits transient `--inject`
inputs, and leaves the destination ref unchanged on nonzero command exit or
commit failure. It composes with the existing save/fork path: commit stable disk
preparation once, save one warm machine, then fork children.
Image commit also accepts `--disk-size SIZE` to sparsely grow the root block
device before the setup command. The size is absolute, 64 KiB aligned, and
cannot shrink the resolved source. SporeVM records the appended capacity as
known-zero chunks, enables growth-session virtio-blk `WRITE_ZEROES`, and asks
the managed initrd agent to invoke `EXT4_IOC_RESIZE_FS` directly from verified
device geometry. Growth does not invoke the image shell, and no `resize2fs` or
e2fsprogs package is required in the image. Growth sessions use internal
`noinit_itable` handling so
checksum-enabled ext4 layouts finish inode-table initialization before commit.
The same pre-mount source check and around-ioctl revalidation apply to commit.
Source/index validation, growth, bounded geometry validation, and setup all fail
closed before the destination ref is replaced.

This release breaks saved-spore, disk, memory, and rootfs cache formats.
Existing pre-unified saved spores and old flat/disk-layer cache entries should
be treated as invalid and rebuilt from source images or recreated from fresh
runs.

Disk state now uses `spore-disk-index-v1` chunk indexes everywhere. Writable
rootfs saves write `chunk-index-disk-v0` manifests whose identity is the BLAKE3
digest of the disk index, not a linear hash of flat ext4 bytes or a layer-chain
head. RAM manifests use the same index shape with their own chunk size, so disk
and memory now share the same parser and canonical index digest machinery.
The v1 parser enforces the canonical indent-2 JSON bytes already emitted by disk
and rootfs producers, including fixed field order and lowercase digest
references, so reformatting cannot create a second identity for the same map.
Existing official disk/rootfs index identities remain unchanged. Local RAM
backing proofs created with the earlier compact fingerprint safely fall back to
verified chunks and are regenerated with the shared canonical encoding by a
subsequent save or fork.

Cold starts from chunked rootfs storage no longer need to rebuild the whole
flat ext4 file before boot. When the flat materialization cache is absent or
stale, SporeVM opens the verified index over a sparse runtime base and faults
local CAS chunks in on first read. Missing or corrupt chunk objects fail the
complete multi-chunk virtio-blk request before any disk payload bytes are copied;
only the request's I/O-error status byte is written.

Live lazy rootfs runtimes now publish a process-owned cache lease before they
open the index. Destructive rootfs prune and CAS GC preserve unread chunks for
the full foreground-run or named-monitor lifetime, then reclaim them normally
after the runtime disk closes.

`spore pack` now emits chunked rootfs bundles directly from the canonical CAS
index and verified objects. It no longer assembles and rescans a full flat ext4
materialization before export. Packing chunked storage now requires that
canonical CAS; a surviving flat materialization does not repair missing index
or object bytes.

The disk backend is now one chunk-mapped implementation with map-copy fork
support. Forked writable disks get an independent overlay and do not create a
read-depth chain; durable children still come from snapshot plus open.

`spore cache gc --rootfs` is available for the unified rootfs CAS. It marks
reachable indexes and chunk objects from cache metadata, image refs, and live
runtime manifests, and dry-runs by default.
