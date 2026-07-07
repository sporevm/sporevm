# Rootfs Images

For the durable root disk, rootfs CAS, writable layer, bundle, cache, and
verification contract, see [Filesystem And Root Disk Contract](filesystem.md).

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image, installs that image into the local digest cache, and writes chunked
rootfs CAS objects plus a `rootfs_storage` descriptor into the metadata sidecar.
The first OCI-capable run workflow is deliberately two-step:

```bash
zig-out/bin/spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

zig-out/bin/spore run --rootfs alpine.ext4 'echo hi'
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

Run a command from a built rootfs by attaching it read-only:

```bash
spore run --rootfs rootfs.ext4 'echo hi'
```

For the direct convenience path, ordinary `spore run --image` resolves the image
ref, builds or reuses a cached ext4 rootfs, and runs a command with the rootfs
attached read-only:

```bash
spore run --image docker.io/library/alpine:3.20 'echo hi'
```

Without `--`, the command runs as `/bin/sh -lc` in the guest. Use
`-- <argv...>` for exact argv. `--image` applies OCI image `Env` and
`WorkingDir` when present. It does not apply OCI Entrypoint, Cmd, or User.

Add `--save` to make rootfs writes part of the spore. The guest still sees a
normal root filesystem, but writes land in a local COW head and save seals
the changed blocks as disk layers:

```bash
spore run --image docker.io/library/alpine:3.20 \
  --save base.spore \
  'echo warmed > /var/tmp/example'

spore run --from base.spore 'cat /var/tmp/example'
```

The rootfs cache key includes the resolved digest-pinned image ref, target
platform, and rootfs builder version. Mutable tag inputs also get a small local
ref record, so a warm `spore run --image docker.io/library/alpine:3.20` or
`spore create --image docker.io/library/alpine:3.20` can go straight to the
previously validated rootfs instead of re-resolving the tag on every invocation.
`--pull=missing|always|never` controls whether mutable refs may use that local
record, force registry refresh, or fail without one. If the ref record or
referenced rootfs is missing or mismatched, SporeVM falls back to the registry
path and updates the record after the rootfs cache is valid. Saved image runs
also require manifest-bound chunked rootfs storage. New builds write it
immediately; older cache entries are upgraded once when
`spore run --image ... --save` needs to record portable rootfs identity.

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

spore run --image local/sporevm-app:dev 'echo hi'
```

`import-oci` accepts either an OCI layout directory or an uncompressed OCI layout
tar like buildx writes. It verifies all `blobs/sha256/*` files against their
filename digest, selects the requested platform from `index.json`, rejects
unsupported manifest/config/layer media types, applies the verified layer tars,
and writes the deterministic ext4 output under the resolved image cache key.

Local refs use the `local/<name>:<tag>` form and are host-local mutable pointers
only. The imported rootfs metadata records a digest-pinned local resolved
identity, `local/<name>@sha256:<manifest>`. Saved image-created spores record
the ext4 BLAKE3 artifact digest and size plus manifest-attached
`rootfs.storage` when available. `spore run --image local/...` resolves from the
local ref cache and does not fall back to a network registry.

Set `SPOREVM_ROOTFS_CACHE_DIR` to choose the cache directory; otherwise SporeVM
uses the platform cache directory. Cache setup messages are shown only with
`spore --debug ...`, so command stdout and stderr stay workload-focused by
default.

OCI layers may contain distinct paths that differ only by case. On hosts with
case-insensitive filesystems, such as the default macOS APFS configuration,
SporeVM uses managed case-sensitive staging for rootfs materialization rather
than corrupting those paths. `SPOREVM_ROOTFS_CACHE_DIR` still overrides the
final ext4/json cache location.

Inspect local rootfs cache usage with:

```bash
spore system df --rootfs
spore --json system df --rootfs
```

Prune rebuildable or reimportable image-rootfs cache entries with a dry run
first:

```bash
spore system prune --dry-run
spore system prune --force
spore system prune --rootfs --dry-run --max-bytes 20gb
spore system prune --rootfs --force --max-bytes 20gb
spore --json system prune --dry-run
```

These commands render human summaries by default. Put global `--json` before the
command when scripts need stable field names and exact byte counts. Without
`--older-than` or
`--max-bytes`, prune selects all default-prunable rootfs entries: rebuildable or
reimportable image-rootfs files that are not hardlinked to digest-addressed
artifacts.

`spore system df --rootfs` also reports rootfs CAS index and object bytes.
`spore system prune --rootfs` does not delete digest-addressed artifacts or
rootfs CAS files by default. The two are distinct data classes with distinct
prune selectors:

- `--include-digest-artifacts` prunes the flat digest-addressed ext4 artifacts,
  which are the resume authority. Removing one makes affected spores fail
  closed until their rootfs bytes are restored (re-pull, or re-materialized
  from surviving chunks).
- `--include-rootfs-chunks` prunes the derived rootfs CAS index and chunk
  objects. This is safe when the flat artifact remains: resume serves the flat
  artifact directly, and `spore pack` re-derives missing chunks from it. Use
  this to reclaim the chunk footprint (roughly the rootfs size per unique
  image) on hosts that pulled chunked spores but do not need to re-share them
  immediately.

When `spore run --image ... --save SPORE` saves a VM, the spore manifest
records an immutable rootfs artifact: the ext4 content BLAKE3 digest, size,
virtio-blk binding, resolved OCI image identity, platform, and builder version.
For image-created spores, the manifest also records `rootfs.storage` pointing at
the chunked rootfs index and CAS object namespace. Any rootfs writes made during
the run are represented as sealed `disk-layer-v0` entries over that immutable
base. Product `spore attach` and `spore run --from` always serve the root
disk base from the flat digest-addressed ext4 artifact, opened under the
verify-at-install, trust-at-open cache contract (see SECURITY.md) without
re-hashing it. `spore pull` and `spore unpack` assemble that artifact from
verified chunk objects at materialization time; if the flat entry is missing
or corrupt at resume (for example after pruning), resume assembles it once
from the locally installed chunks and fails closed when chunks are missing or
the assembled bytes mismatch the manifest artifact digest. Spores without
`rootfs.storage` use the same trusted fd-backed open. If the spore has sealed
writable disk layers, resume also verifies those layer indexes and disk
objects before attaching the layered COW backend.

`spore pack` follows the manifest. Spores without `rootfs.storage` include exact
rootfs bytes under `rootfs/blake3/<hex>.ext4`; spores with `rootfs.storage`
include the descriptor-bound index and referenced chunk objects instead.
`spore unpack` verifies whichever form the manifest selected before writing a
resumable spore.

If a spore manifest has manifest-attached chunked rootfs storage under
`rootfs.storage`, indexed bundles carry the descriptor-bound
`rootfs-block-index-v0` under `rootfs/blake3/indexes/<hex>.json` and the
referenced nonzero rootfs chunk objects under
`rootfs/blake3/objects/<hex>.chunk`. `spore unpack` and `spore pull` verify the
index against the manifest descriptor, verify each chunk by BLAKE3, and install
those files into the destination host's rootfs CAS cache. They do not require
the monolithic ext4 digest-cache artifact on the destination for a chunked
rootfs child.

`spore rootfs cas-preload <blake3:digest> --attach-spore DIR` remains available
for repairing or upgrading an existing exact-rootfs spore. It is no longer the
normal image-build or image-capture path.

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
bundled exact rootfs bytes or chunked rootfs CAS bytes through the same verified
materialization boundary. HTTP peer hosts must resolve only to public IP
addresses before fetch. Use
`SPOREVM_ROOTFS_CACHE_DIR` to choose the destination rootfs cache and
`SPOREVM_BUNDLE_CACHE_DIR` to choose the node-local bundle and memory chunk
caches used by pull. Pull JSON reports `rootfs.cache.hit_count`,
`rootfs.cache.miss_count`, `rootfs.cache.bytes_fetched`, and
`rootfs.cache.bytes_reused` so repeated pulls can prove a warm digest or CAS
cache is not refetching or reinstalling rootfs bytes.

Plain `spore run --rootfs PATH` remains a local read-only run escape hatch.
Named `spore create --rootfs PATH` records exact immutable rootfs identity in
the digest cache for lifecycle saves. Combining one-shot `spore run
--rootfs PATH` with `--save` is rejected until an import/preload command can
record chunked portable rootfs identity for arbitrary local images.

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
SPORE_GENERATION=42
SPORE_PARENT_GENERATION=41
SPORE_VM_ID=spore-...
SPORE_FORK_BATCH_ID=...
SPORE_RESUME_TIME_UNIX_NS=...
```

For the first local fan-out contract, `SPORE_PARALLEL_JOB` is the child index
within the local `spore fork --count N --out DIR` batch and
`SPORE_PARALLEL_JOB_COUNT` is `N`. The generation JSON also retains
`fork_index`, `fork_count`, `generation`, `parent_generation`, and resume-time
fields; the fork fields currently match the parallel fields. Distributed
offsets, remote ranges, and global shard numbering are deferred.

Live rootfs fan-out resumes the already-running process tree. Such processes
should discover child identity by reading `/run/sporevm/env` or
`/run/sporevm/generation.json` after resume, not by expecting their inherited
environment to change. `/run/sporevm` is runtime metadata, not rootfs image
content, and a live snapshot can contain older files until the guest agent
refreshes them. Sharded live workloads should wait for fresh child generation
metadata before starting work; for a pre-fork parent capture, require the fork
batch, parallel fields, and `SPORE_GENERATION > SPORE_PARENT_GENERATION`.
Harnesses that can read the child manifest can compare the exact expected
generation.

The guest agent mixes the resume-time entropy seed into the kernel RNG before a
forked `spore run --from` command starts. Live-forked processes can still carry
process-local RNG state copied from the parent, so entropy-sensitive workloads
must reexec, reseed their own runtime, or wait behind an application-level
after-restore hook before generating secrets.

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
