# Filesystem And Root Disk Contract

SporeVM exposes root storage to the guest as a normal `virtio-blk` disk. The
host may serve that disk from an exact ext4 artifact, a chunked rootfs CAS, or
sealed writable disk indexes, but the guest-visible contract stays block-based.
Filesystem-level diffs, FUSE, 9p, NFS, and file-content indexes are not restore
authority.

## Rootfs Production

`spore rootfs build` materializes an OCI image into a deterministic ext4 image,
installs that image into the digest cache, and writes chunked rootfs CAS storage
by default:

```text
$SPOREVM_ROOTFS_CACHE_DIR/
  <image-cache-key>.ext4
  <image-cache-key>.json              # includes rootfs_storage
  by-digest/blake3/<rootfs>.ext4      # exact fd-backed compatibility path
  cas/rootfs/blake3/indexes/<id>.json # spore-disk-index-v1
  cas/rootfs/blake3/objects/<id>.chunk
```

`spore run --image ... --save` is the writable-rootfs product path. It
records the immutable ext4 artifact, records `rootfs.storage` from the metadata
sidecar for image-created spores, and captures rootfs writes as a sealed disk
index over that base. Older image cache entries miss under the flag-day cache
identity and are rebuilt from the source image rather than migrated. `spore
rootfs cas-preload --attach-spore` remains a repair/debug path for existing
exact-rootfs spores; it is not the normal producer path.

`spore build` uses the same descriptor-bound indexes and writable head. Before
the first executor-backed instruction, the current builder v9 retains the v8
capacity contract and computes
`max(parent_logical_size, 16 GiB)`. A smaller supported journal-less parent is
extended once with authoritative clean-zero chunks; a parent already at or
above 16 GiB retains its exact geometry. There is no recursive headroom rule or
build capacity override. The transient growth profile offers virtio-blk
`WRITE_ZEROES`, and the managed initrd invokes `EXT4_IOC_RESIZE_FS` from the
visible device size, so the zero range remains sparse and the growth path
invokes neither the image's shell nor `resize2fs`.

The grown canonical index is published as a complete rootfs before a typed
builder-v9 `PREPARE` record makes it reusable. Its key binds the immutable
parent index, exact target, platform, and exact kernel/initrd plus growth
protocol identity. `--no-cache` bypasses Dockerfile step-record reads but still
reuses PREPARE because capacity normalization is infrastructure, not a
Dockerfile result. RUN/COPY/ADD/WORKDIR keys separately bind the same exact
executor identity. The managed default derives that identity from canonical
kernel and embedded-initrd digests without reading the artifact bodies on a
fully cached build; a later miss verifies the once-opened kernel bytes and
boots that same allocation. Explicit overrides are eagerly retained. Old
builder-v8, builder-v7, and builder-v6 records remain conservative GC roots but
miss under v9; existing rootfs indexes and local images remain readable. Failed
growth, quiescence, completeness, PREPARE, step, or ref publication never
rewrites the parent or makes incomplete storage reachable.

`RUN --mount=type=cache,target=...` state lives in one host-local,
4 GiB sparse aggregate ext4 disk under the rootfs cache, protected by its own
exclusive lock. The disk is a transient writable virtio-blk attachment during
build execution and never enters a rootfs index, image, or Spore manifest. Each
omitted ID is `path.Clean` of the target after Dockerfile expansion and before a
relative target is joined to `WORKDIR`; an explicit ID is an opaque expanded
string. Both select the same domain-separated BLAKE3-named directory inside the
aggregate disk, so equal resolved IDs share storage without becoming host path
authority. `sharing=shared` and `sharing=locked` are accepted, but both are
conservatively serialized by the aggregate lock and the existing whole-build
rootfs-cache lock. The guest bind-mounts those directories in
instruction order, unmounts them in reverse order after killing RUN descendants,
syncs and cleanly unmounts the cache filesystem, and removes target directories
it created before the rootfs freeze handshake. Failed RUN writes are retained,
but cleanup failure blocks the checkpoint and step record. One RUN accepts at
most eight mounts. A symlinked, non-regular, size-mismatched, bad-magic, or
host-visible unclean aggregate disk is recreated before reuse; a guest mount
rejection remains a build error. The current `spore rootfs df`, prune, and GC
surfaces do not account for or remove this bounded host-local cache disk.
BuildKit v0.30.0 retains cache options in RUN result identity only when the
effective ID value equals the resolved destination and sharing is `shared`;
otherwise it clears ID and sharing. Spore matches that value-based quirk: an
explicit shared ID equal to its target is indistinguishable from the historical
absolute omitted-ID case, while an omitted relative target whose destination
later joins `WORKDIR` is cleared. An edit can therefore hit without opening the
newly named store or miss and execute according to those effective values.

`RUN --mount=type=bind,source=<file>,target=<path>` accepts only an immutable
regular file from the build context and the default read-only bind policy.
Source and target expand from the instruction-start ARG/ENV snapshot; the
source is normalized as one literal relative context path and the target is
normalized beneath `WORKDIR` when relative. `.dockerignore`, missing files,
directories, symlinks, special files, parent traversal, globs, writable binds,
custom options, and stage/image/named-context sources fail during full-file
planning. Root targets, trailing-slash targets, and targets overlapping
`/proc`, `/dev`, `/sys`, `/run/sporevm`, `/run/buildkit`, or
`/etc/resolv.conf` are also rejected, including ancestors that would hide a
protected path and descendants that would alter one. Before cache lookup or VM startup, each
selected file's path, mode, and BLAKE3 content digest enter ordered RUN
identity. A miss streams the file once into the existing immutable context
capture and exposes only that sealed regular file from the read-only context
disk. The same race-checked source stat captures nanosecond mtime for that
transport inode. Presence and value select a v2 context-disk producer identity;
disks without captured mtime retain v1, and ordinary COPY/ADD entries retain
their zero-timestamp behavior and semantic identity. BuildKit deliberately excludes bind source mtime from semantic RUN
identity: an mtime-only edit can hit the old RUN result, but a later miss
observes the newly captured mtime. Values outside the ext4 signed-epoch range
(1901-12-13 through 2446-05-10) fail on a miss before execution rather than
truncating or wrapping.

The strict newline-terminated v4 RUN request carries at most eight captured
source paths and canonical absolute targets, optionally composed with the
landed default cache mounts and optional-absent SSH declaration. The agent
opens both source and target without following symlinks, bind-mounts the source
read-only, and then enters the operation-owned RUN sandbox. An absent target is
represented by an owned empty file; an existing regular file is covered and
restored unchanged. After descendant cleanup, binds are unmounted in reverse
order and only the target plus empty ancestor components created by setup are
removed. A sibling file created by RUN makes its parent ordinary preserved
rootfs state. The bind transport inode, mountpoint, and owned target scaffolding
never enter the rootfs checkpoint; ordinary files that RUN writes from bind
data remain persistent output. Unmount failure, path replacement, or unverifiable ownership
poisons the build session and blocks step, cache-record, and ref publication.

One exact `RUN --mount=type=ssh` declaration is accepted only as optional-absent
compatibility when the caller supplies no SSH input. For that RUN, the builder
adds `SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` only when the effective
environment does not already define the key, matching BuildKit's observable
precedence. It creates no socket or `/run/buildkit` path and adds no guest
request field, host input, or forwarding transport. The resolved environment
and a typed `ssh_declared_absent` bit enter RUN cache identity, but neither the
inert value nor any mount state enters image config or a rootfs checkpoint. A
command that tests or connects to the nonexistent socket fails normally and
publishes no failed step. Options, duplicate SSH declarations, required or
custom sockets, secrets, and all credential-bearing forms remain fail-closed.

Mutable public HTTPS ADD inputs are fetched and BLAKE3-hashed before their
step-record lookup. Their typed key binds the resolved URL and destination,
the safe response `Content-Disposition` filename or URL-path fallback, actual
content digest, resolved numeric mode (default `0600`),
validated optional `Last-Modified` timestamp, instruction-start ENV/ARG state,
platform, parent, and executor identity. A valid HTTP-date is applied as the
destination mtime through the confined guest COPY path; absent or malformed
dates use the Unix epoch. A build accepts at most 64 such instructions, 1 GiB
of combined response bodies, and ten minutes of combined host-fetch time or
the smaller build timeout. The private synced staging file is deleted after the
context-disk apply path has either completed or failed. If a process crashes,
the next remote ADD staging session removes abandoned files after acquiring the
directory lock; only the existing complete rootfs CAS child and its step record
become reusable authority.

The public HTTPS single-file form also accepts `--chmod=<octal>`. The operand
uses the same instruction-start expansion rules as other builder-owned fields,
must resolve to `0` through `07777`, and enters both the immutable context-disk
source inode and the ADD input digest. The unchanged strict COPY v4 request
then applies that inode through the existing confined guest copy path, so mode
and `Last-Modified` mtime remain independent. Empty, symbolic, malformed,
duplicate, and out-of-range modes fail before an ADD request is sent.

A single unquoted `COPY <<NAME destination` heredoc becomes one immutable
root-owned `0644` regular file in that same context-disk pipeline. Its bounded
body expands from the instruction-start ARG/ENV snapshot without consuming
literal quote bytes, then the builder hashes the exact resolved bytes and the
delimiter-derived source name before cache lookup. The existing strict COPY v4
request applies the file, so a trailing-slash destination uses `NAME` as the
basename and ordinary COPY owns destination conflicts and checkpoint cleanup.
The canonical heredoc source, resolved destination, workdir, environment
state, parent, and executor identity complete the step key. Quoted or
tab-chomping delimiters, multiple or mixed heredoc sources, COPY flags on the
form remain fail-closed.

Context `COPY --parents` uses the same immutable capture and strict COPY v4
apply path. The host maps each selected file, directory, or glob root to its
ordered cleaned root-relative destination below the resolved `WORKDIR` target,
then binds that mapping and the captured bytes and modes into COPY identity.
`--parents=false` is ordinary context COPY. The context-root operands `.` and
`./`, internal `/./` pivots, stage or named-context sources, `--link`,
heredocs, and other flag combinations remain unsupported. The synthetic tree
merges reconstructed directories only with existing directories (including
confined symlinks to directories); a file or non-directory conflict fails
without unlinking either the root destination or a nested entry. Unlike
BuildKit, which exposes captured source mtimes on a cold
parents copy while excluding them from semantic cache identity, Spore keeps
the existing deterministic Unix-epoch context-COPY timestamps. An mtime-only
edit therefore hits in both builders, but a forced Spore miss still emits zero
timestamps; the frozen compatibility workload does not inspect them.

A single unquoted, non-chomping `RUN <<NAME` heredoc uses the ordinary RUN
filesystem transaction. Its non-empty, non-shebang body is preserved with the
final newline and streamed to `/bin/sh -c`; the guest shell, rather than the
builder operand expander, owns ARG/ENV substitution, quoting, escaping, unset
variables, and parameter operators. The exact canonical body, effective
environment, workdir, resources, network, parent, executor, and any ordered
default cache mounts remain step inputs. The existing RUN sandbox, timeout,
reverse-order cache teardown, freeze, and publication rules are unchanged.
Shell-prefix, quoted, chomping, multiple, empty, shebang/direct-exec, and
exec-form heredocs remain fail-closed before execution.

Automatic growth supports SporeVM's journal-less native ext4 profile and
journal-less layouts from SporeVM's e2fsprogs writer, or equivalent layouts the
pinned guest kernel can online-grow. Before the first writable mount, the initrd
reads the primary superblock and rejects journal presence, recovery or
journal-device flags, filesystem error or orphan state, a nonzero legacy orphan
head, and the orphan-file pending-cleanup flag. A frozen journal-less checkpoint
does not need the clean-unmount bit. After mount, the initrd re-reads and
validates the same source-state fields before any resize mutation and validates
them again after `syncfs`. The product-default growth mount uses internal
`noinit_itable` so new inode tables initialize synchronously; a guarded
engineering negative control is the only path that omits it. The retained
fixtures cover native and journal-less metadata-checksum/uninitialized-group
filesystems. Unknown or unsupported features and inconsistent geometry fail
closed. SporeVM neither guesses at a host-side rewrite nor falls back to a guest
`resize2fs` process.

A format-valid source may end partway through its final 64 KiB chunk. Growth
preserves and, for CAS sources, verifies that old prefix, materializes at most
that one chunk, and exposes only sparse zero bytes after the old logical end.
Known-zero partial tails remain metadata-only. Allocation, read, write, or
resize failure leaves the source map, digests, dirty state, and logical size
unchanged.

`spore run --image ... --commit local/name:tag` uses the same writable head but
publishes its sealed root disk as a new indexed local image after a successful
guest command. The transaction holds the rootfs cache lock from snapshot
sealing through the completeness stamp, metadata write, and atomic local-ref
replacement, so concurrent rootfs collection cannot remove an unpublished CAS
object. Failed commands and failed snapshots do not update the ref.
With `--disk-size`, SporeVM first resolves the source image config and requires
a complete, descriptor-bound rootfs index, then validates the requested
absolute size against that immutable source. Referenced chunks remain subject
to the normal CAS verification contract. The size must be 64 KiB aligned and
cannot shrink the source; an equal size is an idempotent no-op.
Only the run's private sparse head is extended, and the appended range enters
the chunk map as authoritative clean zeros rather than allocated payload. The
growth-only virtio-blk profile accepts `WRITE_ZEROES`, so ext4 zeroing can clear
those ranges without proportional overlay or CAS storage.

Before starting the user command, the managed initrd performs the pre-mount
source validation above, mounts with the product-default internal
`noinit_itable` policy, derives the visible device size with `BLKGETSIZE64`, and
revalidates the source state before invoking `EXT4_IOC_RESIZE_FS`. After the
ioctl it syncs the filesystem and validates that state again. The primary ext4
superblock block count must increase, stay at or below the device-derived
target, and miss it by less than one ext4 block group. The host independently
validates the exact response against the same invariants while `statfs` supplies
free-space/inode diagnostics only. This path does not execute the image's shell
or require `resize2fs` or any other guest package. A missing or mismatched
source, rejected preflight, invalid geometry, failed zeroing or ioctl, or
malformed result aborts before the destination ref changes. The committed
rootfs descriptor and disk index use the grown logical size; the immutable
source index remains unchanged.

Plain `spore run --rootfs PATH` is still a local read-only escape hatch. Named
`spore create --rootfs PATH` records exact immutable rootfs identity in the
digest cache, so lifecycle saves can restore through the fd-backed rootfs
path. Combining one-shot `spore run --rootfs PATH` with `--save` is rejected
until an import path can record chunked portable rootfs identity for arbitrary
local images.

`spore run --inject ID=PATH` injects caller-provided bytes into
`/run/sporevm/injected/ID` for a fresh run. The bytes are appended to the run
initrd and, when a rootfs is attached, copied into the rootfs `/run` tmpfs
before the command starts. They are not installed into the image rootfs cache or
the immutable rootfs artifact. Spore rejects `--inject` with `--save` and
`--from`; `--commit` allows injection because tmpfs state is outside the root
disk. A guest command that explicitly copies those bytes onto the root disk is
deliberately making them persistent.

## Manifest Authority

The manifest, not a path, tag, cache entry, or bundle index, is the restore
authority.

- `rootfs.artifact` records the ext4 materialization identity, size, format,
  device binding, and OCI provenance. For spores with `rootfs.storage`, the
  artifact digest must equal `rootfs.storage.index_digest`; the flat ext4 file
  is only a cache keyed by that index identity. Spores without
  `rootfs.storage` keep the older exact fd-backed digest path.
- `rootfs.storage.kind: "chunked-ext4-rootfs-v0"` selects the chunked rootfs
  base. The descriptor binds device, logical size, chunk size, hash algorithm,
  object namespace, `index_digest`, and `base_identity`. For this storage kind,
  `base_identity == index_digest`.
- `disk.kind: "chunk-index-disk-v0"` records sealed writable root disk bytes as
  a `spore-disk-index-v1` in the rootfs CAS namespace. `disk.base` is the index
  digest; `chunk_size`, `hash_algorithm`, and `object_namespace` bind the
  descriptor used to open and verify the index and objects.

OCI refs and local image ref records are provenance or cache hints only.

## Runtime Path

Product attach and run-from restore build one root disk backend:

```text
virtio-blk
  -> one-level chunk map
  -> sparse local overlay for writes
  -> flat or sparse base fd selected by disk/rootfs index
```

The flat materialization is the hot runtime base source. For immutable rootfs
materializations, the open follows the verify-at-install, trust-at-open cache
contract (see SECURITY.md): exact fd-backed entries were BLAKE3-verified when
installed, while chunked entries were derived from a digest-verified index and
BLAKE3-verified chunk objects. Opens check symlink-safety, regular-file shape,
and exact size instead of re-hashing the flat file. When the flat cache is
missing or stale, the runtime opens the selected disk/rootfs index over a
sparse temporary base fd. Nonzero index entries start as `.cas` map entries;
the first read verifies the local chunk object against the descriptor-selected
BLAKE3 digest, writes it into the sparse base, and promotes the map entry to
the hot `.base` path. Serving repeated guest reads with plain preads on one fd
is what keeps resume-to-first-command fast. The runtime first publishes a
process-owned baseline lease while holding the rootfs cache lock. Both
foreground runs and named monitors keep that lease until their runtime disk is
closed, so destructive prune or GC cannot remove a still-unread CAS object.

Chunked rootfs storage (`rootfs.storage`) is a distribution and dedupe format,
and now also the local cold-start fallback when a flat materialization is not
available. `spore pull` and `spore unpack` can still assemble flat
materializations from verified chunk objects, but `spore run` and restore do
not need to publish a flat by-digest cache entry before boot. An inconsistent
artifact/index pairing fails closed when the index is opened; missing or
corrupt chunk objects fail a lazy multi-chunk, multi-descriptor read before any
disk payload bytes are copied; virtio still writes the request's I/O-error
status byte.

Missing or corrupt rootfs indexes, chunk objects, exact artifacts, disk indexes,
or disk chunk objects fail before guest code can observe unverifiable bytes.

## Writable Disk Indexes

Writable rootfs state is represented as a sealed chunk index:

```text
chunk-index-disk-v0
  base: blake3:<spore-disk-index-v1 bytes>
  chunk_size: 65536
  chunks: logical_chunk -> blake3:<chunk-bytes>
  zero_chunks: [...]
```

Active writes stay local in a sparse writable head. Capture writes nonzero
chunks into `cas/rootfs/blake3/objects/`, writes the canonical
`spore-disk-index-v1` under `cas/rootfs/blake3/indexes/`, then durably publishes
its derived completeness stamp before the pin and visible save. The manifest
disk records that index digest. Canonical indexes use the exact field order,
two-space JSON layout, lowercase digest references, and no trailing newline
specified in `docs/spore-format.md`; differently encoded aliases are rejected.
Restore attaches the verified index to the
chunk-mapped backend; referenced chunk objects fault into the sparse base fd on
first read and then use the same hot `.base` path as a materialized image.

## Distribution

`spore pack` follows the selected manifest. Machine-local saves may keep
writable-disk indexes and objects only in the global rootfs CAS. A validated
host-private durable pin, not the save path, keeps that storage reachable across
save moves and cache GC/prune. Pack resolves saved-local storage first and then
the pinned global CAS, verifies the canonical index and every object while
copying, and emits a self-contained bundle that still restores after the source
CAS and pin are removed. Raw copies share the source pin identity and can be
invalidated when either copy is removed; fork or pack/unpack creates an
independent lifecycle.

- spores without `rootfs.storage` include exact rootfs bytes under
  `rootfs/blake3/<hex>.ext4`;
- spores with `rootfs.storage` include the descriptor-bound index under
  `rootfs/blake3/indexes/<hex>.json` and referenced chunks under
  `rootfs/blake3/objects/<hex>.chunk`;
- spores with writable disk indexes include the `spore-disk-index-v1` named by
  `disk.base` and referenced nonzero disk chunk objects under the same
  `rootfs/blake3` index/object paths.

For chunked rootfs storage, pack reads the canonical index and its verified CAS
objects directly while holding the rootfs cache lock. The manifest already
binds `rootfs.artifact.digest` to that index identity, so packing neither needs
nor recreates the derived flat ext4 materialization.

`spore unpack` and `spore pull` fully materialize one selected child before
resume. They verify bundle identity, selected manifests, RAM chunks, rootfs
artifacts or CAS bytes, and disk index/object bytes before writing a resumable
spore. The resulting disk-backed spore owns a descriptor-bound complete CAS
locally, so `spore rm --spore` removes and syncs the self-contained directory
without requiring or unregistering a host-private durable pin. Removal fails
closed while a live runtime owns that directory as its lazy disk baseline.
Direct S3 and digest-pinned HTTP peer pulls are byte sources only; they never
become restore authority. HTTP peer hosts must resolve only to public IP
addresses; loopback, link-local, private, multicast, and reserved targets are
rejected before a GET is issued.

Metadata-only exact-rootfs bundles are an explicit prepared-cache opt-out:
`--rootfs=metadata-only` on pack and `--allow-metadata-only-rootfs` on
unpack/pull. Chunked rootfs storage is bundled by default for new image-created
spores.

## Cache Inspection And Pruning

`spore system df --rootfs` reports image ext4 files, metadata, exact digest
artifacts, rootfs CAS indexes, rootfs CAS objects, ref records, and temporary
entries. `spore cache gc --rootfs` performs a mark/sweep of rootfs CAS indexes
and objects from cache metadata, ref records, live runtime manifests, and
process-owned lazy-runtime leases; it is dry-run by default and requires
`--force` to delete candidates. Destructive prune consults the same runtime
leases before selecting explicit CAS entries.
Current build step records are roots. GC also reports recognized legacy and
stale build step records, removes them under the rootfs cache lock on `--force`
before the CAS sweep, and preserves unknown future record kinds or schema
versions conservatively.

Default `spore system prune --rootfs` only selects rebuildable image rootfs
entries. Flat digest artifacts are skipped unless `--include-digest-artifacts`
is passed with an age or size bound. Canonical rootfs CAS chunks are skipped
unless `--include-rootfs-chunks` is passed.
That shared namespace also holds writable-disk state: pruning it can break
resume and pack even when a flat rootfs artifact remains. Use root-aware
`spore cache gc --rootfs` to preserve reachable state.

## Evidence

The default manifest-attached rootfs CAS path is materially faster than the
historical verify-on-open fd-backed control on local HVF for
`docker.io/library/node:22-alpine`:

```text
count  baseline median TTI  manifest CAS median TTI
10     7031.5 ms            606.0 ms
100    6983.5 ms            561.5 ms
```

The same benchmark showed median rootfs verification dropping from about 3.35s
and 536.9MiB hashed to about 270-284ms and 31.98MiB hashed for the sparse Node
working set.

The later trust-at-open flat-artifact preference removed the remaining
per-chunk object-open cost from warm resume. On the same local HVF
Node workload, the CI benchmark profile measured warm `spore run --from`
median TTI dropping from 391ms (CAS chunk base) to 73ms (flat artifact base),
with guest `node -v` execution time inside the resumed VM dropping from about
300ms to about 22ms. Cold TTI was unchanged.

## Deferred Work

- Broader image-registry measurements for chunk-size tuning.
- Optional file-content indexes if fixed block dedupe leaves measured package or
  model-transfer savings on the table.
- Lazy remote rootfs reads and scheduler-aware peer selection.
- Packfile support if fault-in measurements show file-per-chunk is too costly.
