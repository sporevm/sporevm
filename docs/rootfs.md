# Rootfs Images

For the durable root disk, rootfs CAS, writable disk index, bundle, cache, and
verification contract, see [Filesystem And Root Disk Contract](filesystem.md).

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image, installs that image into the local digest cache, and writes chunked
rootfs CAS objects plus a `rootfs_storage` descriptor into the metadata
sidecar. Local image imports use the same chunked rootfs storage path.
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

Without `--`, a caller command is represented as `/bin/sh -lc <string>`; use
`-- <argv...>` for exact argv. For `--image`, SporeVM prepends OCI Entrypoint
and uses OCI Cmd when no caller command is supplied. A caller command replaces
Cmd but keeps Entrypoint. `--entrypoint PATH` replaces the image Entrypoint;
the caller command still replaces Cmd, or the image Cmd is used when no command
is supplied. Empty or absent arrays contribute no arguments, and an image with
no effective command is rejected before boot. `spore create --image` applies
the same default rules to its optional initial command; plain create without an
image remains an idle VM.

Image `Env` and `WorkingDir` are also applied. `User` currently fails closed:
only empty, `root`, `0`, and those users with an empty, `root`, or `0` group are
accepted because guest credential switching is not implemented. Later named
`spore exec` commands use the saved environment and working directory, but do
not reapply Entrypoint or Cmd.

`spore build` prepares capacity automatically before the first executor-backed
Dockerfile instruction. A supported journal-less rootfs smaller than 16 GiB
grows once to exactly 16 GiB; an image already at or above 16 GiB keeps its
exact size. The policy is absolute and idempotent, so imported OCI images,
existing local images, committed images, and cached intermediates never
recursively double. There is no build disk-size, inode-density, or resize-tool
option.

The appended logical range is authoritative sparse zero storage. During the
one growth boot, the managed initrd validates the primary ext4 superblock
read-only before the first writable mount, derives the visible device geometry,
revalidates the source state before the ioctl and after the resized filesystem
is synced, and calls `EXT4_IOC_RESIZE_FS`; capacity preparation does not invoke
the selected image's shell and needs no e2fsprogs or `resize2fs`. Builder-v9
retains v7's typed `PREPARE` derivation for the complete grown index, keyed by the
parent, exact target, and exact kernel/initrd growth producer. Other Dockerfiles
and `--no-cache` builds that intentionally bypass Dockerfile instruction-cache
reads reuse that preparation without another resize. RUN/COPY/ADD/WORKDIR cache
keys also bind that exact executor identity, so a different agent/kernel cannot
reuse downstream outputs merely because it produced the same prepared bytes. A
miss snapshots and publishes `PREPARE` before step zero, then continues in the
same VM with the digest-bound boot artifacts. Managed-default cache hits do not
read the kernel or initrd bodies; an executor miss verifies and boots the same
once-opened kernel bytes.

The v1 growth contract covers SporeVM's journal-less native ext4 profile and
journal-less layouts produced by SporeVM's e2fsprogs writer, or equivalent
layouts that the pinned guest kernel can online-grow. Before writable mount,
the initrd rejects `has_journal`, recovery and journal-device flags, filesystem
error or orphan state, a nonzero legacy orphan head, and the orphan-file
pending-cleanup flag. A frozen journal-less checkpoint is still accepted when
it lacks the clean-unmount bit. After mount, the initrd re-reads and validates
the same source-state fields before any resize mutation and validates them again
after `syncfs`. The product-default growth mount uses the internal
`noinit_itable` policy so new inode tables finish synchronously; only a guarded
engineering negative control can omit it. The retained corpus includes the
native profile and a journal-less metadata-checksum/uninitialized-group layout.
Other features or topology may still fail kernel online resize or geometry
validation. Every unsupported case fails before PREPARE, step, image, or
destination-ref publication; there is no slow `resize2fs` fallback.

Block or inode exhaustion during COPY/ADD/RUN is terminal for that invocation.
SporeVM does not replay a step that may have external side effects and does not
publish the failed step or destination ref. The v1 16 GiB build cap keeps a
fully populated rootfs index below the current canonical-index limit; a larger
build capacity requires separate index-format/limit work rather than an unsafe
override.

Add `--save` to make rootfs writes part of the spore. The guest still sees a
normal root filesystem, but writes land in a local chunk-mapped head and save
seals the changed chunks as a disk index:

```bash
spore run --image docker.io/library/alpine:3.20 \
  --save base.spore \
  'echo warmed > /var/tmp/example'

spore run --from base.spore 'cat /var/tmp/example'
```

The `--save` target must be a new path. SporeVM creates the output directory
itself before writing memory, disk, and manifest files. Writable-disk bytes
remain in the machine's rootfs CAS and are protected by an opaque durable pin
recorded only in host-private lifecycle metadata. The save directory can be
renamed or moved on the same host. A raw copy shares the original pin identity,
so it has no independent removal lifetime; use `spore fork` for another
machine-local lifecycle or pack/unpack for an independently portable copy.
`spore pack` copies and verifies all required disk storage. The no-copy save fast
path applies only after the machine-local parent already resides in the global
CAS; the first save after portable/local-CAS restore performs a one-time
verified migration into that cache.

Use `--commit local/<name>:<tag>` when the command should produce another
image instead of a resumable machine:

```bash
spore run \
  --image docker.io/library/alpine:3.20 \
  --commit local/alpine-with-tools:dev \
  -- /bin/sh -lc 'apk add --no-cache git'

spore run --image local/alpine-with-tools:dev --pull=never -- /usr/bin/git --version
```

The command runs against a private writable head. Exit zero causes SporeVM to
sync and freeze the guest filesystem, quiesce the virtio block queues, seal the
root disk into the rootfs CAS, and atomically update the local ref. A nonzero
command or commit failure leaves the ref unchanged. The image inherits the full
source OCI config; run-time environment overrides do not edit it.

Commit retains disk state only. It does not retain memory, processes, network
state, or injected files under `/run/sporevm/injected`. A command can
deliberately copy an injected file onto the root disk, in which case the copy is
ordinary committed disk state. The first version accepts fresh non-interactive
`--image` runs only and cannot be combined with `--rootfs`, `--from`, or save
flags. Source and destination may be the same local ref because SporeVM resolves
the source before publishing the result.

Image commit can grow the root disk before setup runs:

```bash
spore run \
  --image local/docker-capable:base \
  --disk-size 20gb \
  --commit local/docker-capable:large \
  -- /usr/local/bin/prepare
```

`--disk-size` is an absolute logical size, must be 64 KiB aligned, and cannot
shrink the resolved source image. An equal size is allowed and performs no
growth. Explicit sizes are still bounded by the 64 MiB canonical-index format:
a sufficiently dense disk above about 30.62 GiB fails snapshot/commit closed,
so use the smallest required capacity. The first version requires `--commit`;
it also requires the fresh
`--image` source to resolve to complete indexed rootfs storage and the
destination to be a valid mutable local ref. SporeVM resolves that immutable
source before opening a private writable head. A missing or mismatched source
fails before boot; when source and destination are the same tag, any later
failure leaves the previous ref unchanged.

For a larger target, SporeVM extends the private head sparsely and records the
appended range as known-zero chunks. A non-resumable growth-session virtio-blk
profile exposes `WRITE_ZEROES`, allowing ext4 zero ranges to remain sparse in
the overlay and rootfs CAS. Before writable mount, the managed initrd applies
the same journal/recovery/error/orphan preflight described above. It then mounts
with the product-default internal `noinit_itable` policy, reads the visible
block-device geometry, revalidates the same source state before any resize
mutation, calls `EXT4_IOC_RESIZE_FS` directly on the mounted rootfs, syncs the
filesystem, and validates that state again. A feature-aware primary superblock
read must show that the filesystem block count increased and reached the
device-derived target within less than one ext4 block group; the host
independently validates the exact response against the same invariants. The
growth step does not invoke the selected image's shell and needs no `resize2fs`
or e2fsprogs. Any source preflight, block growth, zeroing, ioctl, sync, or
response-validation failure aborts before the command and publishes nothing.

Commit is the storage-preparation layer for fan-out, not the warm-machine
layer. Prepare stable dependencies or Docker data into an image, put frequently
changing code above it with `spore build FROM local/...`, then capture one warm
spore and use `spore fork` plus `spore run --from` for children.

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
immediately; older flat-only cache entries miss and are rebuilt or reimported
so the saved manifest can record portable rootfs identity.

When a chunked rootfs has its index and objects but no usable flat
materialization, `spore run` can start from the index directly. The runtime
opens a sparse base fd, verifies each chunk object on first read, and promotes
the verified bytes into that base for subsequent reads instead of rebuilding the
whole ext4 file before boot. Before opening the index, it publishes a
process-owned runtime lease under the rootfs cache lock. Destructive prune and
GC retain the selected index and objects until the foreground run exits or the
named monitor stops.

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
The import also writes chunked `rootfs.storage` for portable saved spores and
bundles. Flat-only imported metadata is no longer a valid cache hit; reimport
the image or tar to record the rootfs storage index identity.

For local BuildKit workflows that do not need OCI metadata, export the final
root filesystem as an uncompressed tar and import that directly:

```bash
docker buildx build \
  --platform linux/arm64 \
  --output type=tar,dest=/tmp/sporevm-app-rootfs.tar \
  .

spore rootfs import-tar /tmp/sporevm-app-rootfs.tar \
  --ref local/sporevm-app:dev \
  --platform linux/arm64
```

`import-tar` records the tar SHA256 as the digest-pinned local identity and then
uses the same deterministic ext4, digest-cache, and `rootfs.storage` path as
`import-oci`. It accepts the BuildKit rootfs tar shape and fails closed on
unsupported PAX xattrs. It does not record OCI `Env`, `WorkingDir`,
`Entrypoint`, `Cmd`, or `User`, so callers must pass a guest command explicitly.

Local refs use the `local/<name>:<tag>` form and are host-local mutable pointers
only. The imported rootfs metadata records a digest-pinned local resolved
identity, `local/<name>@sha256:<manifest-or-tar>`. Saved image-created spores record
the rootfs storage index identity and size plus manifest-attached
`rootfs.storage`. `spore run --image local/...` resolves from the
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
spore cache gc --rootfs
spore cache gc --rootfs --force
spore --json cache gc --rootfs
```

Rootfs cache GC treats current `spore build` step records as roots. Valid
complete builder-v8, builder-v7, and builder-v6 records cannot hit builder-v9 keys, but
remain retained roots for their child storage. Malformed or incomplete known records and
semantically stale current records are pruneable. Unknown future step-record
kinds or schema versions are retained and make the CAS sweep conservative.

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
  which are the hot resume cache for chunked spores and the authority for
  exact-only spores. Removing one makes chunked spores fall back to verified
  CAS chunks; exact-only spores fail closed until their rootfs bytes are
  restored.
- `--include-rootfs-chunks` prunes the canonical rootfs CAS index and chunk
  objects, including writable-disk state in the shared namespace. This can
  break resume and pack even when the flat rootfs artifact remains. Use it only
  for deliberate destructive reclamation; use the root-aware
  `spore cache gc --rootfs` command to preserve reachable state.

`spore cache gc --rootfs` is stricter than prune. It roots descriptor-selected
`spore-disk-index-v1` indexes from cache metadata, image ref records, live
runtime manifests, and process-owned lazy-runtime leases, then selects only
unrooted CAS indexes and chunk objects. It is the preferred command when the
goal is to clean chunk garbage without discarding reachable chunked storage.

When `spore run --image ... --save SPORE` saves a VM, the spore manifest
records an immutable rootfs artifact: the ext4 materialization identity, size,
virtio-blk binding, resolved OCI image identity, platform, and builder version.
For image-created spores, that identity is the `rootfs.storage.index_digest`;
the flat ext4 file is a rebuildable cache. The manifest also records
`rootfs.storage` pointing at the chunked rootfs index and CAS object namespace.
Any rootfs writes made during
the run are represented as a `chunk-index-disk-v0` disk: `disk.base` names a
`spore-disk-index-v1` under `cas/rootfs/blake3/indexes/`, and each nonzero
writable chunk is stored under `cas/rootfs/blake3/objects/`. Product
`spore attach` and `spore run --from` serve immutable rootfs bases from the
flat materialization cache, opened under the verify-at-install,
trust-at-open cache contract (see SECURITY.md) without re-hashing it. Saved
writable disks open from their verified disk index and fault referenced chunk
objects into the sparse runtime base on first read; old `disk-layer-v0` chains
are no longer opened by the runtime restore path. `spore pull` and
`spore unpack` assemble the immutable materialization from verified chunk
objects at materialization time; if the flat entry is missing or corrupt at
resume (for example after pruning), resume opens the local index and faults
chunks on demand, failing closed before unverifiable bytes reach the guest.
Spores without `rootfs.storage` use the same trusted
fd-backed open.

`spore pack` follows the manifest. Spores without `rootfs.storage` include exact
rootfs bytes under `rootfs/blake3/<hex>.ext4`; spores with `rootfs.storage`
include the descriptor-bound index and referenced chunk objects instead.
Spores with a `chunk-index-disk-v0` writable disk include that disk index under
`rootfs/blake3/indexes/<hex>.json` and its referenced nonzero disk chunks under
`rootfs/blake3/objects/<hex>.chunk`.
`spore unpack` verifies whichever form the manifest selected before writing a
resumable spore.

If a spore manifest has manifest-attached chunked rootfs storage under
`rootfs.storage`, indexed bundles carry the descriptor-bound
`spore-disk-index-v1` under `rootfs/blake3/indexes/<hex>.json` and the
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
records the immutable rootfs identity and size without embedding the ext4 bytes.
`spore unpack` and `spore pull` reject those bundles by default. Passing
`--allow-metadata-only-rootfs` makes materialization require that the selected
`SPOREVM_ROOTFS_CACHE_DIR` already contains a trusted rootfs materialization
with the expected shape. It follows the local verify-at-install,
trust-at-open cache contract, so it still fails before writing a resumable
spore if the cache entry is missing, symlinked, non-regular, or size-mismatched.

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
test/smoke/rootfs/oci-run.sh -- /bin/echo hi
```

The smoke prints the metadata path and `resolved_image_ref` so tag-based runs
can be traced back to the digest-pinned image identity that was built.

Tag inputs are resolved to the selected platform manifest before rootfs
materialization. Metadata records both the supplied `image_ref` and the
`resolved_image_ref` used for the build, so builds started from mutable tags can
be repeated from the recorded digest-pinned ref.

Rootfs product platforms use OCI names. `--platform` accepts `linux/arm64` and
`linux/amd64`; backend aliases such as `linux/aarch64` and `linux/x86_64` are
rejected so image metadata and cache identity have one spelling. Platform
metadata support does not imply runtime support: the experimental AMD64
backend currently rejects image and rootfs execution.

`spore rootfs resolve` prints the digest-pinned ref without building a rootfs:

```bash
spore rootfs resolve ghcr.io/org/image:latest --platform linux/arm64
```

The builder verifies fetched blobs against their SHA256 descriptors, applies OCI
whiteouts, rejects unsafe tar paths, and writes the final deterministic ext4
filesystem with SporeVM's native writer.

The generated ext4 image uses UUID and directory hash seeds derived from the
selected OCI manifest digest, normalizes filesystem and inode timestamps to the
Unix epoch, and omits the ext4 journal and metadata checksum features so
repeated builds of the same resolved image produce identical bytes. This
journal-less native profile is inside the automatic-growth support envelope.

Set `SPOREVM_EXT4_WRITER=external` to use the legacy e2fsprogs writer. SporeVM
also disables its journal (and orphan-file feature when supported), keeping
SporeVM-produced external layouts inside the pre-mount growth envelope when
their remaining features and geometry are accepted by the pinned kernel.
`mkfs.ext4` and `debugfs` are auto-detected from `PATH`, common Linux locations,
and Homebrew's `e2fsprogs` prefix. Use `--mkfs` and `--debugfs` to override the
detected binaries for that external fallback.

The current native default uses builder version `sporevm-rootfs-v6`; older
rootfs cache entries are rebuilt once. Rootfs metadata records the selected
writer, so switching `SPOREVM_EXT4_WRITER` forces a rebuild of the v6 cache
entry instead of silently reusing an artifact produced by the other writer.

The first native writer profile uses block maps without extents or
triple-indirect blocks, so a single regular file larger than about 4 GiB fails
closed with `UnsupportedExt4FileSize`. Set `SPOREVM_EXT4_WRITER=external` for
images that need such files until native extents or triple-indirect support
lands. The native profile also omits `dir_index`, so lookup in unusually large
directories remains linear.
