---
status: active
last_reviewed: 2026-07-11
spec_refs:
  - docs/filesystem.md
  - docs/lifecycle.md
  - docs/rootfs.md
  - docs/spore-format.md
  - SECURITY.md
  - src/run.zig
  - src/run_cli.zig
  - src/runtime_disk.zig
  - src/rootfs.zig
  - src/build/exec.zig
related_plans:
  - docs/plans/spore-build.md
  - docs/plans/unified-chunk-disk.md
  - docs/plans/native-ext4-writer.md
---

# Run Image Commit

## Summary

Let a successful one-shot run commit its writable root disk as a normal local
Spore image:

```bash
spore run \
  --image local/docker-capable:base \
  --commit local/project:prepared \
  --inject compose=./compose.yaml \
  --net \
  -- /bin/sh -lc \
    'docker compose -f /run/sporevm/injected/compose pull'
```

`--commit` is an output policy on an otherwise ordinary run. SporeVM executes
the requested command with its existing image, environment, injection,
networking, resource, and event semantics. If the command exits zero, SporeVM
freezes the guest filesystem, snapshots the writable root disk into the rootfs
CAS, and atomically updates the requested local image ref.

The committed artifact contains disk state only. It does not contain memory,
vCPU state, processes, a saved session, network state, or transient injected
files. `spore run --save` remains the distinct whole-machine operation.

This is intentionally application-agnostic. A command may pull Compose images,
populate package caches, download model weights, install a toolchain, or prepare
fixtures. SporeVM does not parse Compose, operate a registry, or edit Docker
metadata.

The implementation reuses the storage machinery already proven by
`spore build`: guest `fsfreeze`, O(dirty) disk snapshots, rootfs completeness,
canonical image identity, and local-ref publication. `spore build` remains the
Dockerfile and cached-recipe frontend; `run --commit` is the direct imperative
escape hatch.

Disk growth now uses the same backend-neutral path as build preparation: a
known-zero sparse tail, a non-resumable virtio-blk `WRITE_ZEROES` profile, and
the fixed `spore-rootfs-grow-v1` managed-initrd request. The agent derives the
target from the visible block device and calls `EXT4_IOC_RESIZE_FS` directly;
the growth step does not invoke the source image's shell and does not need
`resize2fs` or e2fsprogs.

Commit supplies the reusable disk layer for fan-out, not the warm-machine layer.
The intended composition is: prepare and commit the disk once, capture one warm
spore from that image, then use the existing offline `spore fork` plus
`spore run --from` or `spore fanout` path. Starting many independent
`spore run --image` VMs shares storage, but still cold-boots every VM and is not
the warm fan-out experience SporeVM is designed to provide.

## Problem

An image-backed `spore run` already creates exactly the state users want to
retain: an immutable base disk plus a private writable chunk-mapped head. Today
the user can either discard that head or save the entire VM as a resumable
spore. There is no direct operation for retaining only the resulting root disk
as another image.

That gap is visible for nested-container projects. Their native setup command
may already be `docker compose pull`, including Compose's own interpolation,
profiles, includes, builds, and registry behavior. Requiring a second
`inner-images.txt`, translating that command into a Dockerfile, or putting a
registry service inside SporeVM each moves policy away from the tool that owns
it.

The generic disk path already exists:

- image-backed runs resolve immutable image config and indexed rootfs storage;
- writable runs use `ChunkMappedDisk` with a sparse private head;
- `snapshotIndex()` seals dirty chunks while retaining references to unchanged
  rootfs CAS chunks;
- the build executor already freezes the guest before disk snapshots;
- `rootfs.publishIndexedImage()` already publishes complete indexed storage as
  a local image.

The missing product surface is the ability to retain that run's disk head.

## Goals

- Make "run this, then keep the resulting disk as an image" one command.
- Reuse all ordinary fresh-run inputs and controls rather than creating a
  parallel build-command option model.
- Commit only after command success and a quiesced filesystem snapshot.
- Publish an ordinary image consumable by `spore run --image` and
  `spore create --image`.
- Share unchanged chunks with the source image and give every child its own
  writable head.
- Keep application formats and preparation policy opaque to SporeVM.
- Allow transient `--inject` payloads during commit without persisting them
  merely because the root disk is retained.
- Permit source and destination to be the same mutable local ref through
  resolve-first, publish-last ordering.
- Compose with `run --save`, offline `spore fork`, generation identity, and
  `run --from` without adding image-specific fork semantics.
- Let a committed dependency/cache image become the exact `FROM local/...`
  base for a more frequently changing code image, preserving the intended
  stable-to-churny layer order.
- Keep the resulting image backend-neutral across KVM and HVF.

## Non-Goals

- No Docker, Compose, Dockerfile, OCI registry, or containerd metadata parsing
  in the run path.
- No built-in pull-through registry, mirror, credential broker, or image-list
  discovery.
- No host Docker or containerd socket in the guest.
- No automatic command cache. Every requested run executes.
- No claim that filesystem freeze makes an application store clone-safe. The
  command owns daemon shutdown, leases, identity, credentials, and cleanup.
- No image-config editing in the first version. The output inherits source
  image config unchanged.
- No saved-spore, explicit rootfs file, interactive, or live-running commit in
  the first slice.
- No direct `spore fork --image`. Forking an image would mint cold-boot inputs,
  not warm machine children, and would overload the existing fork contract.
- No replacement for `run --save` or offline spore fork. Commit prepares the
  reusable disk base; save/fork remains the warm-state fan-out boundary.
- No general volume, live host-directory mount, or lazy snapshotter contract.
- No secondary COW cache disk in the first implementation. First prove whether
  placing the committed cache below code through the existing local-image
  `FROM` path gives the required invalidation and sharing behavior.
- No new disk-index, image, manifest, or device format.

## User Contract

### One-shot commit

The primary surface is:

```text
spore run --image SOURCE --commit LOCAL_REF [run options] -- COMMAND...
```

For example:

```bash
spore run \
  --image docker.io/library/debian:bookworm \
  --commit local/debian-with-jq:dev \
  --net \
  -- /bin/sh -lc \
    'apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*'
```

The command exit status remains the run's primary status. Exit zero enters the
commit transaction. Nonzero exit skips it and leaves the destination ref
unchanged. A commit failure makes the overall command fail even though the
guest command exited zero.

On success, human output includes the mutable ref, resolved immutable image
identity, and rootfs index digest. JSON/event users receive a bounded
`image_committed` event before the terminal run result.

The destination is a mutable `local/<name>:<tag>` ref in the first version,
matching `spore build -t`. The output image config is the source image config;
the setup command, run environment, working-directory override, network policy,
and injected payloads are not written into it.

### Relationship to save

`--save` and `--commit` answer different retention questions:

| Flag | Keeps root disk | Keeps memory/process state | Output |
| --- | --- | --- | --- |
| neither | no | no | nothing |
| `--commit REF` | yes | no | local image |
| `--save DIR` | yes | yes | resumable spore |

The first version rejects combining them. A user who needs both can commit the
disk or save the machine in separate runs; defining one atomic transaction over
both artifacts is not useful enough to justify its failure semantics.

The names are acceptable because they match familiar meanings: save a running
machine, commit its filesystem changes to an image. Renaming `--save` to
`--snapshot` may make that contrast even sharper before 1.0, but it is an
independent vocabulary decision and not required for this feature.

### Supported sources and conflicts

The first slice accepts a fresh, non-interactive `--image` run only. It rejects:

- `--rootfs`, because a raw rootfs has no source image config or portable local
  image identity;
- `--from`, because saved-spore state has different ownership and may include a
  resumed process tree;
- `--save`, `--save-on`, and `--continue-after-save`;
- `-i` and `-t`, keeping command completion and the commit boundary explicit;
- missing commands and non-local destination refs.

These are deliberately narrow first-slice restrictions, not format limits.

### Disk capacity

Image commit can request an exact larger root disk:

```bash
spore run \
  --image local/docker-capable:base \
  --disk-size 20gb \
  --commit local/docker-capable:large \
  -- /usr/local/bin/prepare
```

`--disk-size` is an absolute logical size, not additive headroom. It must be
64 KiB aligned and at least the resolved source's logical size; equality is an
idempotent no-op, while a smaller request is rejected before boot. The option
requires a fresh `--image` commit with complete indexed rootfs storage and a
valid local destination ref.

Explicit logical size does not bypass the current 64 MiB canonical-index
limit. A sufficiently dense disk above about 30.62 GiB fails snapshot or
commit closed; copyable examples therefore use 20 GiB, which remains encodable
even when fully populated.

For growth, the runtime extends only the private sparse head and marks the
appended range as authoritative clean zeros. The growth-only virtio-blk profile
accepts `WRITE_ZEROES`, allowing filesystem zero ranges to stay free of
proportional overlay and CAS payload. The managed initrd agent reads
`BLKGETSIZE64`, calls `EXT4_IOC_RESIZE_FS` on the mounted rootfs, runs `syncfs`,
and returns bounded block, free-space, and inode geometry. The host requires
the reported device size to match the exact requested target before it starts
the user command.

Growth sessions mount ext4 with the internal `noinit_itable` policy. This is
particularly important for checksum-enabled layouts: newly added inode tables
finish initialization synchronously rather than remaining writable background
work after preparation or commit. The policy is not a user option, and the
growth-only device feature profile is never serialized as portable machine
state.

Source/config/index resolution, shrink and alignment checks, block growth,
zeroing, the ioctl, sync, and response validation are all fail-closed. The
destination ref is not touched until the later commit transaction is complete,
including when source and destination name the same mutable local tag.

### Transient setup inputs

The existing injection path works naturally with commit:

```bash
spore run \
  --image local/docker-capable:base \
  --inject compose=./compose.yaml \
  --inject setup=./prepare.sh \
  --commit local/project:prepared \
  --net \
  -- /bin/sh /run/sporevm/injected/setup
```

Injected payloads remain under `/run/sporevm/injected`, backed by transient
guest runtime state. Unlike `--save`, a disk-only commit can allow injection
without violating its non-persistence contract. If the setup script copies an
injected file onto the persistent rootfs, that copy is intentionally committed.

The existing 16 MiB aggregate injection limit remains. Do not add a broad input
or mount surface speculatively. If real Compose projects need local build trees
larger than that, choose between a generic immutable input disk and named
`create`/`copy-in`/`exec`/commit workflow based on measured ergonomics.

### Incremental refresh

The destination may also be the source:

```bash
spore run \
  --image local/project:prepared \
  --commit local/project:prepared \
  --inject setup=./refresh.sh \
  --net \
  -- /bin/sh /run/sporevm/injected/setup
```

SporeVM resolves the source tag to immutable image metadata before boot and
updates the tag only after the new image is complete. Any failure leaves the
previous ref intact. This gives user-space wrappers an incremental refresh path
without an implicit cache or special registry behavior.

### Fan-out composition

There are two distinct sharing boundaries:

| Boundary | Shares disk chunks | Preserves warm RAM/processes | Fan-out use |
| --- | --- | --- | --- |
| committed image | yes | no | reusable base for independent boots and parent creation |
| saved spore | yes | yes | source for warm offline `spore fork` children |

The end-to-end workflow is deliberately two-stage:

```bash
# 1. Prepare large, stable disk state once. The preparation command must stop
#    Docker or other stateful daemons before returning.
spore run \
  --image local/docker-capable:base \
  --commit local/project:prepared \
  --inject setup=./prepare.sh \
  --net \
  -- /bin/sh /run/sporevm/injected/setup

# 2. Capture the machine-level warm point from the prepared image using the
#    existing run --save lifecycle.
spore run \
  --image local/project:prepared \
  --save warm.spore \
  -- /usr/local/bin/warm-parent

# 3. Mint children that share RAM chunks, rootfs CAS chunks, and the parent's
#    sealed writable-disk CAS.
spore fork warm.spore --count 20 --out children/

# Start fresh per-child commands when the workload should consume generation
# identity before doing shard work.
spore run --from children/000000 -- /usr/local/bin/test-shard
```

`spore fanout children/` remains appropriate when the saved parent has an
attachable process session. A machine-only named save has no session, so its
children use `spore run --from` instead. Commit does not change these existing
session semantics.

This composition has the desired storage shape:

```text
one committed image index and shared rootfs CAS chunks
  + one warm parent spore and its shared RAM/disk chunks
  + N small child manifests and private writable heads
  + actual per-child dirty RAM and disk chunks
```

It also preserves the reason SporeVM has separate image and spore artifacts.
The image is reusable across multiple warm-parent captures, while each saved
spore represents one exact machine warm point and fork generation.

Commit alone does not improve warm TTI. Repeated `spore run --image
local/project:prepared` calls avoid repeated image-store preparation and share
base disk chunks, but each VM still boots and initializes its daemons. The S2
proof must measure both that cold-parent path and the actual saved-spore fork
path rather than reporting storage dedupe as fan-out latency.

The safe generic snapshot boundary keeps nested Docker stopped in the committed
image and starts it independently in each child. Capturing and forking a live
Docker daemon may clone daemon identity, sockets, leases, container state,
process-local RNG, and network assumptions. Proving a runtime-specific
after-fork repair hook is separate work and must not be implied by this plan.

### Layer ordering and cache lifetime

The committed cache must sit below the frequently changing project code. The
wrong ordering is:

```text
stable runtime → code revision → pull inner images → committed image
```

That couples the expensive prepared store to every code revision and makes the
cache difficult to reuse as a base. The intended ordering is:

```text
stable Docker-capable runtime
  → committed inner-image and build cache
  → project code and code-specific setup
  → warm machine spore
  → forked children
```

This can be expressed without a new volume contract because `spore build`
already accepts a local image ref in `FROM`:

```bash
# Refresh only when Compose dependency inputs or the desired inner build cache
# change. Reusing the destination as source makes this incremental.
spore run \
  --image local/project-docker-cache:dev \
  --commit local/project-docker-cache:dev \
  --inject compose=./compose.yaml \
  --net \
  -- /usr/local/bin/refresh-inner-cache \
       /run/sporevm/injected/compose

# Build churny code above the exact committed cache index.
spore build -t local/project-code:dev .
```

The project Dockerfile begins with the cache image:

```dockerfile
FROM local/project-docker-cache:dev
COPY . /work/project
RUN /work/project/prepare-code
```

The first cache creation uses the stable Docker-capable runtime as source; the
example above shows subsequent incremental refresh. A wrapper owns first-run
fallback and derives cache refresh identity from the relevant dependency
inputs. SporeVM does not decide which Compose fields count as dependencies.

With this order, code-only changes reuse the exact same parent disk index.
`spore build` snapshots only code-related dirty chunks above it. When the inner
cache changes, its immutable image identity changes and downstream code steps
invalidate, which is the correct dependency direction.

The Compose cache is not necessarily monolithic. Pulled service images are
usually stable; an inner application image built from project source may change
on every revision. Incremental source-equals-destination refresh still shares
unchanged service-image chunks, but the proof must account separately for
pulled dependencies, inner build-cache changes, and app-image changes.

This rootfs layering is the preferred first design because it uses existing
image, build, CAS, GC, bundle, save, and fork contracts. It fails for projects
that can only provide a monolithic code rootfs which cannot be rebuilt above a
local cache base, or when users need one cache independently attached to many
unrelated rootfs images. Only measured failure on those shapes justifies a
generic secondary COW disk mounted at a guest path such as `/var/lib/docker`.
That larger design would require multiple disk manifests, mount policy,
capture/fork/bundle/GC support for every disk, and one-writer/private-head
semantics.

### Later named workflow

If users need inspection or several preparation steps, add the same disk-only
transaction to named lifecycle:

```bash
spore create prep --image local/base:dev --net -- 'sleep infinity'
spore copy-in prep ./project /work/project
spore exec prep -- /work/project/prepare
spore commit prep --tag local/project:prepared --stop
```

The exact stopped/running semantics require a lifecycle design. This follow-up
would make existing `copy-in` and repeated `exec` operations the large-input and
interactive composition path without adding application knowledge.

Disk-backed named live fork has since landed under
`docs/plans/unified-chunk-disk.md` for unnetworked VMs with one writable rootfs
device. The `--net` preparation example above still cannot live-fork because
networked named fork remains fail-closed, and named commit itself remains a
separate deferred lifecycle operation. Save followed by offline `spore fork`
remains the compatible path for unsupported live layouts.

## Commit Transaction

For a successful fresh image-backed run:

1. Resolve the source ref to immutable image config and complete indexed rootfs
   storage before starting the VM.
2. If `--disk-size` is present, validate its absolute aligned size against the
   resolved source and extend only the private sparse head with known-zero
   chunks. Boot the non-resumable growth profile, issue
   `spore-rootfs-grow-v1`, and require the initrd agent's ioctl and bounded
   geometry result to match the visible target before continuing.
3. Execute the command using the existing run path.
4. If the command exits nonzero or the client is interrupted, tear down without
   publishing anything.
5. Ask the guest agent to freeze the root filesystem using the existing bounded
   `fsfreeze-v1` request.
6. Drain the relevant virtio-blk queue and snapshot the writable disk index into
   the rootfs CAS.
7. Convert the disk descriptor to `RootfsStorage`, verify completeness, and
   publish canonical image metadata with the inherited source config.
8. Atomically replace the requested mutable local ref only after all immutable
   chunks and metadata are durable.
9. Tear down the guest and release runtime resources. A post-publication cleanup
   warning does not make a complete committed image invalid.

Publication must be safe against concurrent rootfs GC. Hold the cache lock from
snapshot completion through completeness marking and ref update, or install a
temporary GC root until the mutable ref is durable. Refactor
`publishIndexedImage()` into lock-aware pieces if its current lock ownership
would otherwise recurse.

Filesystem freeze creates a block-consistent point, not application-level
clone safety. A background Docker daemon or database may still hold identity,
leases, active-container metadata, or unflushed application state. The user's
command must stop and clean application daemons before returning success.

## Safety And Correctness Invariants

- **Opaque rootfs.** Host code never parses or edits application metadata.
- **Immutable source.** The source image and its index are never mutated.
- **Private writable head.** A commit seals the run's head into a new flat chunk
  index; children receive independent future heads.
- **Disk-only output.** No RAM, vCPU, process, console, session, or network state
  is present in the image.
- **Atomic destination.** Command, freeze, snapshot, completeness, metadata, or
  publication failure leaves the previous destination ref unchanged.
- **Transient injection.** Injected bytes do not become image content unless the
  guest explicitly copies them to persistent storage.
- **No hidden cache.** Invoking a commit always runs the command.
- **No secret guarantee.** If the command writes a credential into the rootfs,
  the committed image contains it.
- **Source-equals-destination safety.** Source resolution completes before any
  possible destination ref replacement.
- **Absolute source-bound growth.** Disk size is validated against the resolved
  source, never interpreted as an increment, and never shrinks or mutates that
  source.
- **No guest-tool dependency.** Filesystem growth is a fixed managed-initrd
  ioctl request; image contents cannot replace the grower or select its target.
- **Quiescent growth completion.** Internal `noinit_itable` handling prevents a
  checksum-enabled filesystem from reporting preparation complete while lazy
  inode-table initialization can still dirty the disk.
- **Non-resumable growth profile.** Growth-only `WRITE_ZEROES` negotiation is
  used only before a rootfs-only commit and cannot enter saved machine state.
- **Backend-neutral artifact.** The output contains architectural rootfs state,
  not KVM or HVF machine state.

`SECURITY.md` must document the artifact boundary and the difference between
transient injection and files deliberately written to the persistent rootfs.
The feature adds no new attacker-influenced storage parser; if implementation
does add one, the repository's bounded parsing and fuzz requirements apply.

## Existing Building Blocks

Already landed:

- `spore run --image` resolves an image and owns a private writable chunk-mapped
  root disk for the run.
- `spore run --inject` transports small transient payloads into guest runtime
  state.
- `runtime_disk` already accepts an internal rootfs growth target.
- `build/exec.zig` already freezes, snapshots, converts disk storage, marks
  completeness, and publishes rootfs-only checkpoints.
- `rootfs.publishIndexedImage()` publishes complete indexed storage under a
  local image ref.
- rootfs GC marks chunks from image refs and runtime manifests.

Added by S0 and S1:

- `--commit` parsing, compatibility checks, help, result output, and libspore
  contracts;
- a shared disk-descriptor-to-`RootfsStorage` conversion used by build and run;
- run-path freeze, rootfs snapshot, completeness, and local-ref publication;
- an exclusive cache lock spanning snapshot sealing through ref replacement;
- transient `--inject` support for disk-only commits while whole-machine save
  retains its existing rejection;
- absolute, fail-closed disk growth before the requested command through the
  shared known-zero, growth-session `WRITE_ZEROES`, and managed-initrd ext4
  ioctl path, with no guest package dependency;
- backend-neutral smoke scripts plus durable rootfs, lifecycle, security, API,
  and release documentation.

## Delivery Strategy

Implementation progress:

- [x] S0 implementation: one-shot image commit, full source-config inheritance,
  lock-safe CAS/ref publication, human and JSON events, transient injection,
  API result flag, docs, and HVF smoke coverage.
- [x] S0 fan-out proof: commit, save, offline two-child fork, and isolated
  per-child writable heads over the committed base.
- [x] S0 review/commit.
- [x] S1 implementation: absolute chunk-aligned disk sizing, known-zero sparse
  growth, pre-command managed-initrd ext4 ioctl, growth-session `WRITE_ZEROES`
  and `noinit_itable`, shrink rejection, API/docs, and HVF smoke coverage.
- [x] S1 review/commit.
- [x] S2 downstream decision gate: the real Buildkite code image cannot be
  represented above the committed cache with the current build contracts; the
  proof stopped before collecting measurements for the wrong layer order.

### S0 — One-shot `run --commit`

Implement the narrow fresh-image path with existing injections and the source
image's current logical disk size.

Expected touchpoints:

- `src/run.zig`: parse `--commit`, reject incompatible modes, retain source
  image config, and orchestrate freeze/snapshot/publication after exit zero;
- `src/run_cli.zig`: report mutable ref, immutable image identity, rootfs index,
  and bounded errors;
- `src/build/exec.zig` plus the appropriate shared disk/rootfs module: extract
  disk-descriptor conversion without changing build behavior;
- `src/rootfs.zig`: make publication lock ownership safely reusable;
- `src/api.zig`: expose optional commit request/result without CLI formatting;
- `docs/rootfs.md`, `docs/lifecycle.md`, CLI help, and `SECURITY.md`: document
  the artifact and injection contracts.

Tests:

- accept `--image REF --commit local/REF -- COMMAND`;
- reject raw rootfs, saved-spore, save, interactive, missing-command, and remote
  destination combinations;
- commit a marker on exit zero and read it from a network-disabled child;
- prove an injected file is absent unless explicitly copied to the rootfs;
- prove nonzero exit, freeze failure, snapshot failure, completeness failure,
  and publication failure preserve a pre-existing destination ref;
- prove source and destination may be the same local tag safely;
- prove source and sibling images remain immutable;
- from the committed image, create a saved spore with writable rootfs, offline
  fork at least two children, start a fresh command in each child, and prove
  shared base storage plus private child writes;
- preserve existing run, build, save/restore, rootfs accounting, and GC tests;
- run the real-hardware smoke identically by hand and on supported KVM and HVF
  lanes.

Done when a successful run produces an ordinary image with only dirty chunks
added to rootfs CAS, every pre-publication failure is fail-closed, and help
clearly distinguishes commit from whole-machine save.

Expected PR boundary: one SporeVM PR with the run flag, reusable internal disk
publication transaction, tests, help, lifecycle/rootfs docs, and security text.
No Docker/Compose code and no manifest-format change.

### S1 — Generic disk capacity

Expose absolute `--disk-size SIZE` for image-backed runs, initially required
only with commit. Reuse the shared known-zero sparse grow path, enable the
non-resumable rootfs-growth `WRITE_ZEROES` profile, and issue the fixed direct
ext4 ioctl request through the managed initrd before the user command. Reject
shrinking, require exact bounded geometry, and publish no image if block-device
or filesystem growth fails. Do not depend on the source image's shell or
filesystem tools.

This is a generic resource option for any large prepared rootfs, not Docker
storage configuration.

### S2 — Prove Compose composition downstream

Use a downstream wrapper to inject or otherwise stage the project's Compose
configuration, run its installed Compose implementation, stop application
daemons cleanly, and commit the disk image.

Build the project code from the committed cache ref with `FROM local/...`; do
not prepare the inner cache on top of an already code-specific image. Exercise
three invalidation cases separately: code-only change, pulled service-image
change, and inner app-image/build-cache change.

Measure against archive-copy plus `docker load`:

- cold preparation time and registry bytes;
- output logical size and unique rootfs CAS bytes;
- independent image boot time and nested-runtime-ready time;
- warm-parent capture time, offline fork time, and per-child
  resume-to-first-command time;
- guest peak RAM;
- shared RAM/rootfs/disk bytes and incremental private bytes after 1, 10, and
  100 children where practical;
- refresh behavior using the previous prepared tag as source.
- code-only rebuild behavior proving the committed Docker cache index remains
  the exact parent and no inner pull/load step reruns;
- unique bytes caused by code, stable service images, and inner app-image
  rebuilds, reported separately.

Done when there is no hand-maintained image list, network-disabled children use
the prepared store, siblings have private writes, offline fork remains a cheap
metadata/share operation, and measured resume/storage results demonstrate the
intended prepare-once/fan-out-many experience.

If code-only changes cannot be represented above the committed cache base on
the real workload, stop and record why. That evidence is the decision gate for
a separate COW cache-disk plan; do not quietly add secondary disks to S2.

Expected PR boundary: downstream only. Any missing generic input or lifecycle
primitive must be planned before widening SporeVM.

#### S2 outcome (2026-07-10)

The downstream pressure test against `buildkite/buildkite-sporevm` confirmed
that the existing wrapper has the inverse order: it first builds the
revision-specific `buildkite-spore-ci:local` image, then adds individually
saved dependency archives, and finally runs `docker load` during guest setup.

The Buildkite CI Dockerfile at
`2f31a768d9423507e9b864e1634b0064c17cf3da` cannot currently be rebuilt from
`FROM local/buildkite-compose-cache:dev`. It combines its runtime and code with
multi-stage output, cross-stage copies, remote and heredoc inputs, BuildKit
cache/bind/SSH mounts, and COPY flags outside the supported `spore build`
subset. SporeVM can consume the resulting monolithic image as a base, but
cannot apply it as a child delta above an already committed cache image.

S2 therefore stopped at its explicit decision gate. No Compose pull or fan-out
numbers were collected: they would measure a code-first cache whose lifetime
is invalidated by the common code-only change. No secondary disk or
Docker-specific feature was added. A follow-up must first prove one generic
way to put code above the cache: a stable application runtime plus narrow code
recipe, an independently applicable rootfs delta, or runtime source staging.

### S3 — Consider named commit

Only after one-shot use demonstrates a need, design `spore commit NAME --tag
REF [--stop]`. Reuse the exact image-publication transaction and resolve monitor
ownership, filesystem freeze, running-command policy, disk locking, stale
runtime records, source image config, and stop semantics explicitly.

Do not couple this to disk-backed named live fork. Named commit exports an
image; disk-backed monitor fork is a separate lifecycle operation that has
since landed for the single writable-rootfs shape. Named save plus offline fork
remains the compatible fan-out path for networked or additional-device layouts.

## Verification

### Functional

- Exercise local, digest-pinned remote, and mutable source refs under each pull
  policy.
- Verify shell and exact-argv commands, environment, working directory,
  networking, timeout, injection, and event behavior remain ordinary run
  semantics.
- Verify source config inheritance and absence of run-only settings from output
  config.
- Verify `--disk-size` accepts an equal-size no-op and an aligned absolute grow,
  rejects unaligned sizes and shrink attempts before boot, and works from an
  image with no shell or e2fsprogs installed.
- Verify native and checksum-enabled ext4 sources grow through the same request,
  checksum-enabled growth uses `noinit_itable`, and no background inode-table
  writes remain before the command or snapshot.
- Verify output images work with `run`, `create`, accounting, prune, and every
  existing local-image consumer.
- Verify commit → save → offline fork → per-child `run --from` preserves
  generation identity and writable-rootfs isolation.
- Verify `spore fanout` session behavior is unchanged: it attaches only when the
  saved parent has a session, while machine-only children use `run --from`.

### Failure And Recovery

- Interrupt during command execution, freeze, snapshot, completeness marking,
  metadata write, and local-ref replacement.
- Inject guest grow timeout, `WRITE_ZEROES` backend failure, ioctl/sync failure,
  malformed or mismatched grow geometry, freeze timeout, ENOSPC,
  corrupt/missing CAS objects, and metadata failures.
- Prove every growth failure and every invalid or incomplete source leaves a
  pre-existing destination ref unchanged, including source-equals-destination.
- Run rootfs GC at every legal publication boundary.
- Retry after each failure without manual cache repair.

### Storage And Performance

- Compare source and output indexes to prove unchanged descriptors remain
  shared.
- Prove appended logical zeros allocate no proportional sparse-head or CAS
  payload and that snapshot work scales with changed ext4 metadata chunks.
- Record dirty chunks, new CAS bytes, sparse-head bytes, index size, and
  freeze/snapshot/publication time.
- Establish that commit cost scales with dirty chunks, not logical rootfs size.
- Confirm offline fork of a writable-rootfs spore links shared disk CAS and RAM
  stores instead of copying the committed container-image payload per child.
- Measure independent image boots separately from warm child resumes so the
  result cannot mislabel disk dedupe as fan-out TTI.
- In the Compose proof, separate registry transfer, guest unpack, base-store
  growth, and per-child writes.

## Key Learnings From Pressure-Testing

- The most direct mental model wins: the user is already running the command
  and should be able to choose whether its writable disk is discarded or
  committed.
- Commit solves the reusable disk-base problem, not warm fan-out by itself.
  Existing save/offline-fork remains the machine-state layer; the plan now
  requires their composition as an end-to-end acceptance path.
- Layer order is as important as dedupe: preparing Docker state above churny
  code gives the cache the wrong lifetime. The downstream proof stopped because
  the real Buildkite image cannot yet make the committed cache its exact parent;
  measuring the existing code-first image would validate the wrong design.
- A secondary COW disk would give stronger cache/rootfs independence, but it
  expands manifest, mount, capture, fork, bundle, and GC contracts. It is a
  fallback behind evidence that inverted rootfs layering cannot serve the real
  workload.
- Independent runs from a committed image have good storage sharing but still
  cold-boot. Adding `fork --image` would blur that distinction and is rejected.
- Offline `spore fork` supports saved writable disks by sharing their CAS, and
  named live fork now supports one unnetworked writable rootfs. Named commit
  still must not be presented as unlocking networked or additional-device live
  fork.
- Putting imperative execution under `spore build` would duplicate run options,
  overload the existing cached Dockerfile frontend, and unnecessarily require a
  build context.
- `--save` and `--commit` produce different artifacts, but their names make the
  distinction understandable: save the machine; commit the disk to an image.
  Rejecting their combination keeps failure semantics simple.
- The first implementation can reuse existing injection. A large immutable
  input disk or named commit should be justified by real local-build use cases,
  not bundled into the storage transaction.
- A pull-through registry may accelerate preparation but cannot replace commit:
  each child would still pull, unpack, and store its own image data.
- Filesystem freeze supplies block consistency only. Application consistency
  and clone-safe cleanup remain explicit command responsibilities.
- One-shot commit is the smallest lifecycle change because the run process
  already owns the VMM, disk, command status, and source image config.

## Resolved Decisions

- Add `spore run --commit LOCAL_REF`; do not add imperative command mode to
  `spore build`.
- Keep `spore build` as the cached Dockerfile recipe frontend.
- Commit only after exit zero and publish an ordinary rootfs image.
- Reject `--commit` with `--save`, raw rootfs, saved-spore, and interactive
  modes in the first slice.
- Keep commit and warm capture as two explicit stages: commit the reusable disk,
  then save and offline-fork the exact warm machine point.
- Place the committed dependency/cache image below project code by using it as
  the local `FROM` base for the code build.
- Inherit source image config unchanged.
- Allow existing transient injection with commit.
- Execute every requested commit; leave caching and mutable-input policy to
  callers.
- Permit source and destination to be the same tag through atomic ordering.
- Keep generic disk sizing as absolute, 64 KiB-aligned `run --commit
  --disk-size`; implement growth in the managed initrd and keep guest image
  tools outside the contract.
- Keep Compose and registry policy downstream.
- Defer named commit and large generic inputs until measured use demands them.
- Do not add `spore fork --image`; images are cold-boot bases, spores are fork
  sources.
- Keep secondary COW cache disks out of this change. The Buildkite workload has
  now hit the code-layering trigger, but any separate plan must still compare a
  generic cache disk with simpler application-runtime deltas or runtime source
  staging.

## Deferred Questions And Triggers

- **Rename save to snapshot:** consider before 1.0 if user testing shows
  `--save` versus `--commit` is still confusing.
- **Named VM commit:** add when inspection, repeated exec, or large `copy-in`
  workflows cannot reasonably be one run command.
- **Disk-backed named live fork:** landed for the single writable-rootfs shape
  under `docs/plans/unified-chunk-disk.md`; networked or additional-device live
  layouts remain separate work, while save plus offline fork retains correct
  disk sharing semantics for unsupported layouts.
- **Large immutable inputs:** add when the 16 MiB injection limit blocks real
  projects and named lifecycle is too cumbersome.
- **Image config editing:** design separately when committed images need new
  default command, environment, user, or working directory.
- **Explicit cache keys:** consider only if multiple callers reimplement the
  same immutable-input reuse contract.
- **Separate COW cache disks:** the Buildkite monolithic-image pressure test has
  met the original trigger, but it has not selected this design. Compare it
  first with a stable application runtime, independently applicable rootfs
  deltas, and runtime source staging. If a cache disk remains necessary, a
  separate plan must cover multiple disk manifests, guest mount policy, private
  writable heads, commit/save/fork, bundle/distribution, and GC reachability.
- **Lazy remote chunks:** consider when fresh-host transfer remains dominant
  after local image reuse and normal bundle distribution.

None of these questions blocks S0. The first slice exposes one narrow generic
capability and leaves application policy outside SporeVM.
