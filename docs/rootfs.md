# Rootfs Images

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image. The first OCI-capable run workflow is deliberately two-step:

```bash
zig-out/bin/spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

zig-out/bin/spore run --rootfs alpine.ext4 -- /bin/echo hi
```

The input can be either a digest-pinned ref or a registry tag:

```bash
spore rootfs build ghcr.io/org/image@sha256:<digest> \
  --platform linux/arm64 \
  --output rootfs.ext4 \
  --metadata rootfs.ext4.json

spore rootfs build ghcr.io/org/image:latest \
  --platform linux/arm64 \
  --output rootfs.ext4
```

Run an explicit argv from a built rootfs by attaching it read-only:

```bash
spore run --rootfs rootfs.ext4 -- /bin/echo hi
```

For the direct convenience path, ordinary `spore run --image` resolves the image
ref, builds or reuses a cached ext4 rootfs, and then delegates to the same
read-only rootfs execution path:

```bash
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

The rootfs cache key includes the resolved digest-pinned image ref, target
platform, and rootfs builder version. Mutable tag inputs also get a small local
ref record, so a warm `spore run --image docker.io/library/alpine:3.20` can go
straight to the previously validated rootfs instead of re-resolving the tag on
every invocation. If the ref record or referenced rootfs is missing or
mismatched, SporeVM falls back to the registry path and updates the record after
the rootfs cache is valid.

For local Docker buildx workflows, SporeVM consumes an OCI layout instead of the
Docker daemon or socket. Buildx writes the layout, then `spore rootfs
import-oci` imports it into the same deterministic rootfs cache:

```bash
docker buildx build \
  --platform linux/arm64 \
  --output type=oci,dest=/tmp/sporevm-app.oci \
  .

spore rootfs import-oci /tmp/sporevm-app.oci \
  --ref local/sporevm-app:dev \
  --platform linux/arm64

spore run --image local/sporevm-app:dev -- /bin/echo hi
```

`import-oci` accepts either an OCI layout directory or an uncompressed OCI layout
tar like buildx writes. It verifies all `blobs/sha256/*` files against their
filename digest, selects the requested platform from `index.json`, rejects
unsupported manifest/config/layer media types, applies the verified layer tars,
and writes the deterministic ext4 output under the resolved image cache key.

Local refs use the `local/<name>:<tag>` form and are host-local mutable pointers
only. The imported rootfs metadata records a digest-pinned local resolved
identity, `local/<name>@sha256:<manifest>`, while captured spores continue to
restore by the ext4 BLAKE3 artifact digest and size. `spore run --image
local/...` resolves from the local ref cache and does not fall back to a network
registry.

Set `SPOREVM_ROOTFS_CACHE_DIR` to choose the cache directory; otherwise SporeVM
uses the platform cache directory. Cache setup messages are shown only with
`spore --debug ...`, so command stdout and stderr stay workload-focused by
default.

Inspect local rootfs cache usage with:

```bash
spore system df --rootfs
spore system df --rootfs --json
```

Prune rebuildable or reimportable image-rootfs cache entries with a dry run
first:

```bash
spore system prune --dry-run
spore system prune --force
spore system prune --rootfs --dry-run --max-bytes 20gb
spore system prune --rootfs --force --max-bytes 20gb
spore system prune --dry-run --json
```

These commands render human summaries by default. Add `--json` when scripts need
stable field names and exact byte counts. Without `--older-than` or
`--max-bytes`, prune selects all default-prunable rootfs entries: rebuildable or
reimportable image-rootfs files that are not hardlinked to digest-addressed
artifacts.

`spore system prune --rootfs` does not delete digest-addressed rootfs artifacts
by default because those bytes can be required by existing captured spores and
metadata-only bundles. Add `--include-digest-artifacts` only when you are
comfortable making affected spores fail closed until their exact rootfs bytes
are restored.

When `spore run --image ... --capture SPORE` captures a VM, the spore manifest
records an immutable rootfs artifact: the ext4 content BLAKE3 digest, size,
virtio-blk binding, resolved OCI image identity, platform, and builder version.
The rootfs is also stored under a digest-addressed cache path. Product
`spore resume` reopens that cached artifact, verifies it by digest and size, and
attaches it as the base of the root disk. If the spore has sealed writable disk
layers, resume also verifies those layer indexes and disk objects before
attaching the layered COW backend. If the digest cache entry or any referenced
disk layer data is missing or tampered with, resume refuses to boot.

`spore pack` includes those exact rootfs bytes by default for rootfs-backed
spores, under `rootfs/blake3/<hex>.ext4` in the local bundle. `spore unpack`
requires the bundled artifact, verifies it against the manifest digest and size,
and installs it into the destination host's rootfs digest cache before the
unpacked spore can be resumed.

Indexed bundles also support an explicit prepared-cache mode:
`spore pack SPORE --children CHILDREN --rootfs=metadata-only --out BUNDLE`
records the immutable rootfs digest and size without embedding the ext4 bytes.
`spore unpack` and `spore pull` reject those bundles by default. Passing
`--allow-metadata-only-rootfs` makes materialization verify that the selected
`SPOREVM_ROOTFS_CACHE_DIR` already contains the exact digest-addressed rootfs
bytes; it still fails before writing a resumable spore if the cache entry is
missing or mismatched.

`spore pull file:///path/to/bundle --child 42 --out child.spore` does the same
rootfs installation for indexed local bundles while materializing one selected
child. Digest-pinned remote pulls, such as `spore pull
s3://bucket/prefix@sha256:<bundle_digest> --child 42 --out child.spore` and
`spore pull http://peer:20000/spore.bundle@sha256:<bundle_digest> --child 42
--out child.spore`, first verify the remote bundle identity, then install any
bundled rootfs bytes through the same digest-cache path. Use
`SPOREVM_ROOTFS_CACHE_DIR` to choose the destination rootfs digest cache and
`SPOREVM_BUNDLE_CACHE_DIR` to choose the node-local bundle and memory chunk
caches used by pull. Pull JSON reports `rootfs_cache_hit_count`,
`rootfs_cache_miss_count`, and `rootfs_bytes_fetched` so repeated pulls can
prove a warm digest cache is not refetching or reinstalling rootfs bytes.

Plain `spore run --rootfs PATH` remains a local run escape hatch. Combining
`--rootfs PATH` with `--capture` is rejected until an import/preload
command can record portable rootfs identity for arbitrary local images.

Validate OCI rootfs capture, fork, and parallel `spore run --from` execution
with the opt-in Ruby fan-out smoke:

```bash
mise run smoke:rootfs-fanout
```

Forked rootfs workloads should not read the generation MMIO page directly. The
initrd/rootfs agent publishes the fork generation payload into the rootfs
tmpfs at `/run/sporevm/generation.json` and writes env-style helper lines to
`/run/sporevm/env`:

```text
SPORE_PARALLEL_JOB=0
SPORE_PARALLEL_JOB_COUNT=5
SPORE_VM_ID=spore-...
SPORE_FORK_BATCH_ID=...
```

For the first local fan-out contract, `SPORE_PARALLEL_JOB` is the child index
within the local `spore fork --count N --out DIR` batch and
`SPORE_PARALLEL_JOB_COUNT` is `N`. The generation JSON also retains
`fork_index` and `fork_count` as batch-local fields; they currently match the
parallel fields. Distributed offsets, remote ranges, and global shard numbering
are deferred.

Validate the tag-to-rootfs-to-run path with the local smoke script:

```bash
scripts/smoke-run-oci-rootfs.sh -- /bin/echo hi
```

The smoke prints the metadata path and `resolved_image_ref` so tag-based runs
can be traced back to the digest-pinned image identity that was built.

Tag inputs are resolved to the selected platform manifest before rootfs
materialization. Metadata records both the supplied `image_ref` and the
`resolved_image_ref` used for the build, so builds started from mutable tags can
be repeated from the recorded digest-pinned ref.

`spore rootfs resolve` prints the digest-pinned ref without building a rootfs:

```bash
spore rootfs resolve ghcr.io/org/image:latest --platform linux/arm64
```

The builder verifies fetched blobs against their SHA256 descriptors, applies OCI
whiteouts, rejects unsafe tar paths, and shells out to `mkfs.ext4 -F -d` plus
`debugfs` for the final filesystem.

The generated ext4 image uses UUID and directory hash seeds derived from the
selected OCI manifest digest, normalizes filesystem and inode timestamps to the
Unix epoch, and omits the ext4 journal and metadata checksum features so
repeated builds of the same resolved image produce identical bytes.

`mkfs.ext4` and `debugfs` are auto-detected from `PATH`, common Linux
locations, and Homebrew's `e2fsprogs` prefix. Use `--mkfs` and `--debugfs` to
override the detected binaries.
