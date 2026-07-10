# Release Notes

## Next

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

The disk backend is now one chunk-mapped implementation with map-copy fork
support. Forked writable disks get an independent overlay and do not create a
read-depth chain; durable children still come from snapshot plus open.

`spore cache gc --rootfs` is available for the unified rootfs CAS. It marks
reachable indexes and chunk objects from cache metadata, image refs, and live
runtime manifests, and dry-runs by default.
