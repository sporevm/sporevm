# Release Notes

## Next

`spore fork --vm` now fast-forks disk-backed named VMs with one writable rootfs
device. The source monitor pauses once, drains virtio-blk, captures shared
RAM/machine state, and prepares up to 32 independent disk heads from the same
epoch without sealing dirty disk state. APFS clone and Linux `FICLONE` are the
default path; native-clone failure is closed unless the caller explicitly uses
`--allow-slow-copy`. Networked named fork remains unsupported.

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

`spore run --image SOURCE --commit local/name:tag -- COMMAND` can now publish a
successful one-shot run's writable root disk as an indexed local image. The
commit path freezes the guest filesystem, reuses the quiesced rootfs snapshot
and CAS machinery, preserves source OCI config, permits transient `--inject`
inputs, and leaves the destination ref unchanged on nonzero command exit or
commit failure. It composes with the existing save/fork path: commit stable disk
preparation once, save one warm machine, then fork children.
Image commit also accepts `--disk-size SIZE` to sparsely grow the root block
device and run guest `resize2fs` before the setup command. The size is absolute,
cannot shrink the source, and is published only when resize and setup succeed.

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
