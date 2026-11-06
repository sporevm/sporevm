# Rootfs Images

For the durable root disk, rootfs CAS, writable disk index, cache, and
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
no effective command is rejected before boot. `spore vm create --image` applies
the same default rules to its optional initial command; plain create without an
image remains an idle VM.

When exact argv zero contains no slash, the guest resolves it through the
effective image or per-exec `PATH` using the same bounded selection as
exec-form `RUN`. This changes only the executable passed to `execve`; every
argument remains byte-for-byte unchanged and no shell is involved.

Image `Env` and `WorkingDir` are also applied. `User` currently fails closed:
only empty, `root`, `0`, and those users with an empty, `root`, or `0` group are
accepted because guest credential switching is not implemented. Later named
`spore vm exec` commands use the saved environment and working directory, but do
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

The v1 growth contract covers SporeVM's journal-less native ext4 profile, or
equivalent journal-less layouts that the pinned guest kernel can online-grow. Before writable mount,
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
publish the failed step or destination ref. The 16 GiB build cap keeps a fully
populated rootfs index below the bounded canonical-index limit. The v2 ranged
encoding removes the former roughly 30.62 GiB dense-disk cliff; a larger
automatic build capacity remains a separate product and filesystem decision.

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
remain in the machine's rootfs CAS and are protected by a durable pin
recorded only in host-private lifecycle metadata. The save directory can be
renamed or moved on the same host. Its cache-side ownership anchor makes raw
copies fail closed instead of silently sharing deletion authority. Use
`spore checkpoint fork` for another machine-local lifecycle, or
`spore checkpoint push` and `spore checkpoint pull` to move it to another host.

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
growth. Index inputs remain bounded to 64 MiB, but current v2 indexes pack
contiguous digests and zero ranges instead of emitting a JSON object per
logical chunk; a dense 32 GiB disk is covered by focused tests. Use the smallest
required capacity because metadata still grows with distinct chunk digests.
The first version requires `--commit`;
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
spore and use `spore checkpoint fork` plus `spore run --from` for children.

Pulled, imported, and built images live in a host-local catalog in the rootfs
cache, each identified by its native BLAKE3 image identity over the rootfs
index and canonical config. A pull or import also records which OCI manifest,
index, or tar digest the current rootfs builder converted into that image, so a
digest-pinned ref converts once and then resolves without the registry. Names
such as `local/app:dev` or `docker.io/library/alpine:3.20` are per-platform ref
records pointing at an image, so a warm `spore run --image
docker.io/library/alpine:3.20` or `spore vm create --image
docker.io/library/alpine:3.20` goes straight to the previously converted image
instead of re-resolving the tag on every invocation.
`--pull=missing|always|never` controls whether mutable refs may use that
record, force registry refresh, or fail without one. If the record or the
image's storage is missing, SporeVM falls back to the registry and repoints the
name once the image is published. A new rootfs builder version converts
digest-pinned sources again, and `--pull=missing` resolves a registry tag again
when its image came from an older builder; local names keep pointing at their
images. Images always carry chunked storage, which saved image runs record in
the spore manifest. Caches written by earlier SporeVM versions are not read;
pull, import, or build those images again.

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
and publishes the deterministic ext4 output as a local image with chunked
`rootfs.storage` for portable saved spores. Importing a layout the
current builder already converted only repoints the name.

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

`import-tar` records the tar SHA256 as the image's source digest and then
uses the same deterministic ext4, digest-cache, and `rootfs.storage` path as
`import-oci`. It accepts the BuildKit rootfs tar shape and fails closed on
unsupported PAX xattrs. It does not record OCI `Env`, `WorkingDir`,
`Entrypoint`, `Cmd`, or `User`, so callers must pass a guest command explicitly.

Local refs use the `local/<name>:<tag>` form and are host-local mutable pointers
only. A local ref resolves to `local/<name>@blake3:<image>`; an imported image
is also named by `local/<name>@sha256:<manifest-or-tar>`. Saved image-created
spores record the rootfs storage index identity and size plus manifest-attached
`rootfs.storage`. `spore run --image local/...` resolves from the local catalog
and does not fall back to a network registry.

Set `SPOREVM_ROOTFS_CACHE_DIR` to choose the cache directory; otherwise SporeVM
uses the platform cache directory. Cache setup messages are shown only with
`spore --debug ...`, so command stdout and stderr stay workload-focused by
default.

Set `SPOREVM_DOCKER_HUB_MIRROR` to an HTTPS `host[:port]` such as `mirror.gcr.io`
to pull `docker.io` images through that mirror; refs and digests still name
`docker.io`, and a pull falls back to Docker Hub when the mirror lacks its manifest.

OCI layers may contain distinct paths that differ only by case. SporeVM merges
layers in memory and writes ext4 directly, so those paths stay distinct on
case-insensitive host filesystems such as the default macOS APFS
configuration.

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

Rootfs cache GC treats current `spore build` step records as roots. Records
from older builder versions, malformed or incomplete known records, and
semantically stale current records are pruneable. Unknown future step-record
kinds or builder versions are retained and make the CAS sweep conservative.

These commands render human summaries by default. Put global `--json` before the
command when scripts need stable field names and exact byte counts. Without
`--older-than` or
`--max-bytes`, prune selects all default-prunable rootfs entries: rebuildable or
reimportable image-rootfs files that are not hardlinked to digest-addressed
artifacts, plus host-local regular build cache-mount storage.

`spore system df --rootfs` also reports rootfs CAS index and object bytes. Build
cache mounts appear as the aggregate plus any abandoned emit temp files, with
separate logical capacity and allocated host bytes; prune and GC likewise report
their reclaimed cache-mount bytes separately. `--max-bytes` uses allocated bytes
for these sparse entries, so logical capacity cannot force unrelated image
eviction. In JSON candidate entries, `bytes` remains logical and
`reclaimable_bytes` is the allocated amount; the top-level cache-mount candidate
and deleted byte fields use the allocated amount that cleanup can actually free.
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
  break resume and push even when the flat rootfs artifact remains. Use it only
  for deliberate destructive reclamation; use the root-aware
  `spore cache gc --rootfs` command to preserve reachable state.

`spore cache gc --rootfs` is stricter than prune. It roots descriptor-selected
versioned disk indexes from local image records, live
runtime manifests, and process-owned lazy-runtime leases, then selects only
unrooted CAS indexes and chunk objects. Names and derivations are not roots: an
image pruned by `spore system prune` leaves its names pointing at nothing, and
GC collects its storage. An image record or live runtime manifest whose index
`spore system prune --include-rootfs-chunks` deleted roots nothing. An image
record GC cannot parse keeps every CAS entry. It is the preferred command when the
goal is to clean chunk garbage without discarding reachable chunked storage.
The mutable cache-mount aggregate is not a step-record or image root and is
therefore collectable as a unit. A build holds the store lock while its disk is
open. Prune and GC take the rootfs-cache `flock` and then try the store lock;
while a build holds it they skip the aggregate rather than wait. Process exit
releases those locks even after a crash, and a leftover lock file has no lease
lifetime.
Abandoned regular emit temps are reported and reclaimed by maintenance, and the
next cache-store open scavenges them before reuse.

When `spore run --image ... --save SPORE` saves a VM, the spore manifest
records an immutable rootfs artifact: the ext4 materialization identity, size,
virtio-blk binding, resolved OCI image identity, platform, and builder version.
For image-created spores, that identity is the `rootfs.storage.index_digest`;
the flat ext4 file is a rebuildable cache. The manifest also records
`rootfs.storage` pointing at the chunked rootfs index and CAS object namespace.
Any rootfs writes made during
the run are represented as a `chunk-index-disk-v0` disk: `disk.base` names a
`spore-disk-index-v2` under `cas/rootfs/blake3/indexes/`, and each nonzero
writable chunk is stored under `cas/rootfs/blake3/objects/`. Product
`spore attach` and `spore run --from` serve immutable rootfs bases from the
flat materialization cache, opened under the verify-at-install,
trust-at-open cache contract (see SECURITY.md) without re-hashing it. Saved
writable disks open from their verified disk index and fault referenced chunk
objects into the sparse runtime base on first read; old `disk-layer-v0` chains
are no longer opened by the runtime restore path. If the flat entry is missing
or corrupt at resume (for example after pruning), resume opens the local index and faults
chunks on demand, failing closed before unverifiable bytes reach the guest.
Spores without `rootfs.storage` use the same trusted
fd-backed open.

`spore rootfs cas-preload <blake3:digest> --attach-spore DIR` remains available
for repairing or upgrading an existing exact-rootfs spore. It is no longer the
normal image-build or image-capture path.

`spore checkpoint pull STORE/TAG --out DIR` fetches a spore pushed to an
[image store](image-format.md#spores) into DIR, and the disk index and objects
the cache lacks into the rootfs cache `SPOREVM_ROOTFS_CACHE_DIR` selects.

Plain `spore run --rootfs PATH` remains a local read-only run escape hatch.
Named `spore vm create --rootfs PATH` records exact immutable rootfs identity in
the digest cache for lifecycle saves. Combining one-shot `spore run
--rootfs PATH` with `--save` is rejected until an import/preload command can
record chunked portable rootfs identity for arbitrary local images.

Validate OCI rootfs capture, fork, and parallel `spore run --from` execution
with the opt-in Ruby fan-out smoke:

```bash
test/smoke/fanout/rootfs.sh
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
within the local `spore checkpoint fork DIR --count N --out OUT_DIR` batch and
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
backend executes only native `linux/amd64` image and rootfs content and rejects
cross-architecture cache substitution.

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

The native writer is the only rootfs writer and needs no e2fsprogs. It uses
builder version `sporevm-rootfs-v6`.

The writer maps file data with ext4 block maps rather than extents: direct,
single, double, and triple indirect blocks. Without the `huge_file` feature,
the inode's 32-bit sector count limits one regular file to just under 2 TiB,
and larger files fail closed with `UnsupportedExt4FileSize`; the 32 GiB rootfs
content limit applies first to OCI and tar imports. The profile also omits
`dir_index`, so lookup in unusually large directories remains linear.
