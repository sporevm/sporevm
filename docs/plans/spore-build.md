---
status: active
last_reviewed: 2026-07-11
spec_refs:
  - docs/rootfs.md
  - docs/filesystem.md
  - SECURITY.md
  - src/rootfs.zig
  - src/rootfs_cache.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/chunk_mapped_disk.zig
  - src/build.zig
  - src/build/exec.zig
  - src/build/step_cache.zig
  - src/run.zig
  - src/runtime_disk.zig
  - src/virtio/blk.zig
related_plans:
  - docs/plans/native-ext4-writer.md
  - docs/plans/unified-chunk-disk.md
  - docs/plans/spore-build-rootfs-capacity.md
---

# Spore-Native Dockerfile Subset Builder (`spore build`)

> **Active** (revived 2026-07-09). The native builder now builds the original
> committed `buildkite-sporevm` Dockerfile and runs the resulting image. On
> merged SporeVM main, the acceptance run completed a forced cold build in
> 148.78s, a warm rebuild in 9.87s, and a one-file incremental rebuild in
> 7.31s. The named workflow then reached ready, completed `bin/setup` with live
> untruncated output, and passed 11 examples in a real RSpec file. Remaining
> core work is the Docker-vs-Spore filesystem oracle and exact real-workload
> COPY invalidation proof. Wrapper integration, profiling, repeatable
> benchmarks, and step-record retirement remain follow-ups.
>
> The revival updates M2 onto the unified primitives instead of the original
> flat-file machinery: persistent-session checkpoints are `ChunkMappedDisk`
> overlay state; each per-instruction checkpoint seals dirty chunks and emits
> one canonical full index through `snapshotIndex()`, producing a child
> `index_digest`; the
> guest `fsfreeze` protocol deferred by the unified plan is delivered here;
> and the executor still keys rootfs snapshots by the child `index_digest`.
> Published local image identity additionally includes the final image config:
> the local ref points at a digest over the final `index_digest` plus canonical
> config JSON, with a completeness stamp on the underlying rootfs storage so
> `spore run --image` takes the 0.10s path. The cache model, parser subset,
> COPY semantics, and fail-closed contract below remain valid. Current large
> context work adds a stat-cache for content digests and replaces the deleted
> build COPY entry stream with a cached read-only ext4 context disk.
>
> **Capacity update (2026-07-11).** Build cache v7 separates rootfs capacity
> preparation from Dockerfile instruction caching. The automatic policy is the
> idempotent absolute target `max(parent_logical_size, 16 GiB)`: supported
> journal-less compact images prepare once to 16 GiB, while images already at
> or above 16 GiB retain their exact size. A typed `PREPARE` record reuses that
> normalization across Dockerfiles and under `--no-cache`. On a miss, the
> storage layer appends
> authoritative sparse zero chunks, the transient growth VM exposes
> `WRITE_ZEROES`, and the managed initrd calls the ext4 resize ioctl directly
> before publishing a same-VM checkpoint. There is no recursive growth, hidden
> capacity override, or guest `resize2fs` dependency.
>
> Timing figures retained from the 2026-07-09/10 implementation notes are
> historical baselines. In particular, measurements of the old combined
> grow-plus-first-step path describe the superseded v6 implementation, not v7
> acceptance. Current capacity-specific evidence and gates live in
> `docs/plans/spore-build-rootfs-capacity.md`.

## Summary

Add a `spore build` command that executes a narrow Dockerfile subset directly
against Spore rootfs artifacts, with a deterministic per-instruction cache, so
that a fully cached rebuild resolves the final `index_digest` and updates the
local image ref without booting anything, exporting anything, or touching
BuildKit.

This replaces the earlier direction of optimizing the BuildKit-to-Spore
conversion boundary. That work made import faster and made warm `--image`
resolution effectively instant, but the remaining warm build floor is now
BuildKit's own tar export, typically 25-45s, and content changes still pay the
import path after the tar is produced. This plan removes that boundary entirely:
cached rebuilds resolve the final `index_digest`, update the local ref, and
exit; uncached builds mutate a chunk-mapped rootfs directly and snapshot the
dirty chunks without ever serializing a tar.

The builder does not reimplement BuildKit. It supports exactly the instructions
the `buildkite-sporevm` wrapper's Dockerfile needs — `FROM` (including a named
`--build-context` OCI layout base), shell-form `RUN`, flag-less `COPY`, `ENV`,
`ARG`, `WORKDIR`, `CMD` — and fails closed with an actionable error on
everything else.

## Problem

The current `bin/buildkite-spore build` flow is:

1. `docker buildx build --build-context base=oci-layout://… --output
   type=tar,dest=…`. With all Dockerfile steps cached, the warm flow is now
   about 30s and roughly 25s of that is BuildKit exporting a client tarball.
2. `spore rootfs import-tar …` when the tar content changes. The unified
   import path now emits rootfs CAS objects and the index inline, but a cold
   `buildkite-sporevm` import is still about 95s while the remaining
   `assignBlocks` hotspot is investigated separately.
3. `spore run --image local/buildkite-spore:dev …`, which is already around
   0.10s when the rootfs index has its completeness stamp.

Even when every Dockerfile step is cached, the pipeline serializes a large tar
out of BuildKit just to refresh a local Spore image ref that already has a
complete rootfs index. When content changes, the same boundary forces Spore to
parse the tar and rebuild/index the rootfs instead of applying the changed
instruction directly.

No amount of import optimization fixes BuildKit's export floor, and import
optimizations only help after the tar already exists. The only way to make the
cached path low single-digit seconds, and to make uncached builds avoid tar
serialization, is to build directly on Spore's chunk-indexed rootfs artifacts.

## Goals

- A fully cached `spore build` of the `buildkite-sporevm` Dockerfile completes
  in under one second: hash inputs, resolve the final `index_digest` from the
  step cache, refresh the local ref, exit.
- A partially cached rebuild (one changed trailing instruction) pays only for
  the changed steps and their dirty-only sealing/full-index checkpoints, not for re-exporting or
  re-importing the base.
- The built image is a first-class local Spore image: `spore run --image
  local/buildkite-spore:dev -- /bin/true` resolves and boots it through the
  existing rootfs CAS, completeness-stamp, and local ref machinery with no new
  run-path formats.
- Fail closed on unsupported Dockerfile features with an error naming the
  instruction and a hint pointing at the BuildKit path.
- linux/arm64 only and single-stage Dockerfiles only in the first
  implementation.

## Non-Goals

- No BuildKit compatibility beyond the stated subset. No multi-stage `FROM …
  AS`, `COPY --from/--link/--parents/--chown/--chmod`, `RUN --mount`, `ADD`,
  heredocs, `ENTRYPOINT`, `USER`, `VOLUME`, `EXPOSE`, `HEALTHCHECK`,
  `ONBUILD`, or `--target`. These fail closed.
- No replacement for the wrapper's preliminary `docker build --target ci` of
  the Buildkite app image. That Dockerfile uses `syntax=docker/dockerfile:1.20`
  features (`RUN --mount=type=cache`, `COPY --link`, remote `ADD`, heredocs)
  far outside the subset. The base image keeps arriving as an OCI layout via
  `--build-context`.
- No OCI image/layer output. `spore build` produces Spore rootfs artifacts and
  local refs, not pushable OCI images.
- No flat checkpoint store and no full-image hash fallback in the executor.
  Intermediate and final build states are rootfs CAS indexes produced through
  the unified `ChunkMappedDisk` snapshot path.
- No cross-machine or shared build cache. The step cache is local, same trust
  model as the existing rootfs CAS cache.
- No new persistent device type or portable machine-state contract. The build
  VM uses the existing device set and may attach one transient read-only
  virtio-blk context disk. A non-resumable rootfs-growth session temporarily
  offers `VIRTIO_BLK_F_WRITE_ZEROES` on the existing root block device. The
  guest contracts are `spore-rootfs-grow-v1`, the `fsfreeze` checkpoint
  handshake, and fixed-shape RUN/COPY requests over the existing exec stream.

## Target Model

### CLI

```bash
spore build \
  -t local/buildkite-spore:dev \
  --platform linux/arm64 \
  --build-context base=oci-layout:///path/to/base-oci \
  /path/to/context
```

Options for the first implementation:

- `-t, --tag REF` (required): mutable local ref, `local/<name>:<tag>` only,
  same constraint as `spore rootfs import-*` (`parseLocalTagRef`).
- `-f, --file PATH`: Dockerfile path, default `<context>/Dockerfile`.
- `--platform linux/arm64`: accepted and validated; any other value is an
  error.
- `--build-context NAME=oci-layout://PATH` (repeatable): named base contexts.
  Only the `oci-layout://` scheme is supported initially. `FROM NAME` resolves
  through the existing `importOciLayout` pipeline, cached by manifest digest.
- `--build-arg KEY=VALUE` (repeatable): supplies `ARG` values.
- `--network spore|none`: network policy for `RUN` steps. Default `spore`
  (Docker builds assume network). `none` gives hermetic builds.
- `--no-cache`: ignore Dockerfile step-cache reads (still writes). It still
  reads and reuses the infrastructure `PREPARE` record, just as it reuses OCI
  materialization and other non-Dockerfile normalization.
- `--mkfs PATH` / `--debugfs PATH`: forwarded to the base-import path, same as
  `spore rootfs import-oci`.

Build rootfs capacity is automatic and not user-facing. The builder computes
one target from the immutable `FROM` storage:

```text
automatic_target = max(parent_logical_size, 16 GiB)
```

The 16 GiB value is both the default and the automatic-growth cap. A supported
journal-less compact image grows once to exactly 16 GiB; a 16 GiB or larger
image is unchanged, so reusing a built or committed image never doubles or adds
capacity recursively. There is no hidden override or public capacity knob.
Logical capacity remains sparse and does not reserve 16 GiB of physical
storage.

Before the first executor-backed instruction, the builder resolves a typed v7
`PREPARE` key from the parent index, exact target, and the exact managed
kernel/initrd plus growth-protocol producer identity. A hit becomes the parent
for ordinary Dockerfile keys. On a miss, the same VM that will execute the
remaining steps grows the clean-zero chunk map. Before the first writable
mount, the managed initrd rejects journal, recovery, error, and pending-orphan
state and revalidates that source state around the ext4 resize ioctl. The
builder then freezes and snapshots the prepared filesystem, publishes the
completeness stamp and `PREPARE` record, thaws, and continues with step zero.
The selected image needs no `/bin/sh` or `resize2fs` for preparation.

`FROM` also accepts existing image refs directly (`FROM local/foo:dev`,
`FROM local/foo@sha256:…`), resolved through `resolveLocalCachedRef`. Registry
refs (`FROM debian:bookworm`) reuse the existing OCI resolution used by
`spore run --image`, in a later milestone.

Unsupported features fail closed at parse time, before any execution:

```
error: unsupported Dockerfile instruction: RUN --mount=type=cache
hint: this Dockerfile needs BuildKit; use docker buildx + spore rootfs import-tar
```

Every parse error names the file, line, and instruction. The whole Dockerfile
is validated before step one executes, so a build never fails halfway through
on a feature error.

### Supported subset, exactly

| Instruction | Support |
| --- | --- |
| `FROM <name>` | named `--build-context` (oci-layout), local ref, digest ref. No `AS`, no `--platform` flag. |
| `RUN <shell>` | shell form only, executed as `/bin/sh -c` in the guest as root. No `--mount`, no `--network`, no heredoc, no exec form in v1. |
| `COPY <src>… <dest>` | context-relative sources, files and directories. No flags. |
| `ENV K=V` / `ENV K V` | build env + final image config. |
| `ARG K[=default]` | value from `--build-arg` or default; unset used ARG is an error (stricter than Docker's warning; surfaced as a decision below). |
| `WORKDIR /path` | affects `RUN` cwd, `COPY` relative dest, final config. Created in the guest if missing, matching Docker. |
| `CMD ["…"]` / `CMD <shell>` | final image config only; both JSON exec form and shell form are supported. |
| comments, line continuations, `${VAR}`/`$VAR` substitution in instruction arguments | Parser directives such as `# syntax=` and `# escape=` are rejected anywhere in the file, not only in Docker's leading directive window. |

Variable substitution applies to `ENV`, `ARG` defaults, `WORKDIR`, `COPY`
arguments, and `CMD`, using the declared `ARG`/`ENV` state, as Docker does.
`RUN` strings are not pre-expanded; the guest shell expands them, with
`ARG`/`ENV` values exported into the step environment. Only `$NAME` and
`${NAME}` substitution are in the subset; parameter-expansion operators such as
`${NAME:-default}`, `${NAME:+alt}`, `${NAME#prefix}`, and `${NAME%suffix}` fail
closed.

## Architecture

New module family, backend-neutral, sibling to the existing rootfs code:

```
src/build_cli.zig        CLI parse + dispatch (registered in src/main.zig
                         next to "rootfs"/"run")
src/build.zig            orchestrator: plan, cache walk, step execution,
                         final ref publication
src/build/dockerfile.zig subset parser -> []Instruction, fail-closed,
                         fuzz target required (new parser of
                         user-influenced input per SECURITY.md)
src/build/context.zig    .dockerignore-aware context walking, stat-cache
                         memoization, and content hashing for COPY
src/build/context_disk.zig
                         read-only ext4 context disk emission/reuse for
                         executed COPY steps
src/build/step_cache.zig step-key computation + on-disk records that map
                         deterministic parent+instruction inputs to child
                         index_digest outcomes, including the typed v7
                         PREPARE normalization record
src/build/exec.zig       persistent build-VM session: boot the deepest
                         cached index writable through ChunkMappedDisk,
                         perform direct-ioctl capacity preparation when
                         needed, drive RUN/COPY through initrd agent requests,
                         checkpoint (freeze/snapshot/stamp/record/thaw)
                         after each build step
```

Build state machine:

```diagram
╭────────────╮   ╭──────────────╮   ╭──────────────────────────────╮
│ parse +    │──▶│ resolve FROM │──▶│ first executor instruction:  │
│ validate   │   │ → base index │   │ target=max(parent, 16 GiB)   │
│ Dockerfile │   │   blake3     │   │ resolve typed PREPARE key    │
╰────────────╯   ╰──────────────╯   ╰──────────────┬───────────────╯
                                                   │
                 PREPARE hit / already large       │ PREPARE miss
                     ╭─────────────────────────────┴──────────────╮
                     ▼                                            ▼
          ╭────────────────────────╮                ╭────────────────────────╮
          │ prepared child becomes │                │ boot parent once; clean │
          │ Dockerfile-key parent  │                │ zero grow + direct ext4 │
          ╰────────────┬───────────╯                │ ioctl; freeze/snapshot; │
                       │                            │ stamp + PREPARE; thaw   │
                       │                            ╰────────────┬───────────╯
                       ╰─────────────────────────────┬───────────╯
                                                     ▼
                                        ╭────────────────────────╮
                                        │ hit: walk Docker keys; │
                                        │ boot child on first miss │
                                        │ miss: execute remaining │
                                        │ steps in the live VM    │
                                        ╰────────────┬───────────╯
                                                     ▼
                                        ╭────────────────────────╮
                                        │ step → freeze/snapshot │
                                        │ → stamp/record → thaw; │
                                        │ publish final image ref │
                                        ╰────────────────────────╯
```

The orchestrator threads a `BuildState` through the instruction list:

```zig
const BuildState = struct {
    storage: RootfsStorage,      // current parent rootfs index + geometry
    capacity_target: u64,        // fixed once from immutable FROM storage
    env: []const EnvPair,       // base config Env, then ENV accumulation
    args: []const ArgPair,      // declared ARG values
    workdir: []const u8,        // current WORKDIR
    cmd: ?[]const []const u8,   // CMD, metadata only
};
```

`BuildState` seeds from the base image's stored `ImageConfig` (the import
metadata sidecar already carries it): `env` starts as the base config `Env`
(so `RUN` sees the base's `PATH`, `RUBYOPT`, etc., as Docker does), `workdir`
starts as the base `WorkingDir` (default `/`), and `cmd` starts as the base
`Cmd` so an override-free Dockerfile inherits it. Base config values need no
extra keying: they are a pure function of the base rootfs index that already
roots the chain.

Metadata-only instructions (`ENV`, `ARG`, `CMD`) advance `step_key` and
`BuildState` without touching the rootfs; their child `index_digest` is the
parent `index_digest`. `WORKDIR` updates the same state but is also a
filesystem step: the guest creates the directory when needed and publishes a
child rootfs index. `RUN` and `COPY` likewise produce new rootfs indexes.

Reused existing machinery, unchanged:

- `importOciLayout` (`src/rootfs.zig:779`) resolves `--build-context`
  oci-layout bases, cached by manifest digest — a base that was imported last
  build is a cache hit.
- `rootfs_cas` + `disk_index` store chunk objects and `spore-disk-index-v1`
  bytes named by `index_digest`; complete stamps make known-good rootfs
  indexes O(1) to re-open.
- Local ref records (`refs/local/<sha256>.json`, `writeLocalRefCache`) and the
  image metadata path make the result visible to `spore run --image` with no
  run-path changes.
- The run/exec stack (`run_mod.execute`, vsock exec protocol, exit codes,
  `--net` gateway) executes guest steps.

## Cache Model

### Checkpoints, not layers

`spore build` has no layer concept. The artifact of every step — and of the
final image — is one rootfs `index_digest` naming a `spore-disk-index-v1` plus
its referenced 64KiB rootfs CAS objects. OCI layers exist only at the `FROM`
edge, parsed once by the existing import path and never re-emitted. There is no
Docker overlay stack, no whiteout resolution at build or run time, and no
flatten/export pass; the run path consumes the indexed rootfs unchanged.

The three jobs Docker layers perform are covered separately:

- **Caching**: deterministic step records map
  `parent index_digest + instruction + inputs` to a recorded child
  `index_digest`. A cache hit resolves a rootfs index, not a layer stack.
- **Storage sharing**: unchanged chunks are shared by the rootfs CAS. During an
  uncached session, `ChunkMappedDisk` keeps only overlay-backed dirty chunks in
  memory/file-backed state and `snapshotIndex()` publishes only those dirty
  chunks into CAS when the guest is frozen.
- **Distribution/dedupe**: the existing rootfs CAS and `spore-disk-index-v1`
  are the dedupe unit for both intermediate checkpoints and final images.

Accepted one-way door: built images cannot be exported back to Docker (there
are no layers to emit). Checkpoint granularity is the chunk-indexed rootfs
state, and the cache records are local build metadata over those indexes.

### Step keys

Build cache v7 has two typed derivations in the same record namespace. The
synthetic `PREPARE` operation normalizes capacity before Dockerfile cache keys
are resolved; RUN, COPY, and WORKDIR then use the prepared child as their
ordinary parent. A key is a cache lookup address, and the record at that address
stores the child `index_digest` produced by the prior successful execution.

```
prepare_key = blake3_framed(builder_version_v7, platform,
                            parent_index_digest, "PREPARE", exact_target,
                            producer_identity)

step_key = blake3_framed(builder_version_v7, platform,
                         prepared_parent_index_digest, instruction_kind,
                         canonical_instruction, input_digest, env_digest,
                         workdir, network_mode, executor_identity)
```

Every field is length-framed, and optional fields carry an explicit presence
tag. `disk_grow_target` is absent from v7 Dockerfile inputs and records. The
producer identity binds the exact kernel and initrd bytes that will boot plus
the growth request, mount/no-lazy-init policy, transient WRITE_ZEROES contract,
and preparation host-contract version. The same exact-byte identity is carried
as `executor_identity` in every RUN/COPY/WORKDIR key: two producers that happen
to emit the same PREPARE child cannot reuse each other's executor results.
Paths and hypervisor backend are not identity inputs. For managed defaults,
the identity uses the canonical SHA-256 from the bounded read-only kernel
sidecar and the build-generated SHA-256 of the embedded initrd, so a fully
cached build reads neither artifact body. A later miss opens the kernel once,
verifies those bytes against the bound digest, and boots the same allocation.
Explicit kernel/initrd overrides remain eager: the executor loads, hashes,
retains, and boots those exact bytes.

Per-instruction inputs:

- `FROM`: the resolved base `index_digest` (not the ref, not the manifest
  digest). Re-importing the same OCI layout yields the same rootfs index
  identity and the same chain; a changed base image invalidates everything.
- `PREPARE`: fixed canonical instruction/kind `PREPARE`, immutable FROM parent
  `index_digest`, exact target, and producer identity. Its validated child must
  have the exact requested logical size and preserve the parent's rootfs device,
  chunk size, hash algorithm, and object namespace.
- `RUN`: the exact command string, the current `WORKDIR`, and the network mode.
  The environment digest is an ordered, length-framed sequence of accumulated
  `ENV` entries followed by typed `ARG` records (key, presence bit, value),
  including list counts. It preserves duplicate ENV order, distinguishes ENV
  from ARG state and unset ARG from an explicitly empty value, and cannot alias
  embedded newlines with multiple entries. `input_digest` is empty.
- `COPY`: the substituted source patterns and dest, the current `WORKDIR`,
  and `input_digest` = the context content hash of the matched sources:
  after sorting by relative path and deduplicating repeated matches, each
  matched entry contributes length-prefixed fields to one BLAKE3 stream:
  `u64le(len(path)) || path || u64le(len(type)) || type ||
  u64le(len(mode)) || mode || u64le(len(payload)) || payload`. The payload is
  file content, symlink target text, or empty bytes for a directory.
  Ownership is not hashed (COPY forces 0:0). mtimes are not hashed
  (Docker parity).
- `ENV` / `ARG` / `CMD`: metadata instructions update the state consumed by
  later execution keys. A changed `ENV` or `ARG` invalidates later `RUN`/`COPY`
  steps, while a final `CMD` keeps the same rootfs `index_digest` and costs only
  a local ref/config re-publish.
- `WORKDIR`: the normalized absolute path and current state key the filesystem
  step that creates the directory. A changed `WORKDIR` publishes a new child
  index and invalidates later `RUN`/`COPY` steps.

`network_mode` is present only for `RUN`; COPY keys are deliberately invariant
across `--network spore` and `--network none` because COPY never uses the build
VM network.

`--no-cache` bypasses only RUN/COPY/WORKDIR record reads. It deliberately still
reads `PREPARE`: forcing Dockerfile execution must not repeat stable
infrastructure normalization, replace the prepared parent with another valid
kernel-produced index, or reintroduce cold resize cost. An isolated preparation
benchmark uses a separate cache instead of a user-facing bypass.

`ARG` follows this simplification: a declared ARG's value enters the effective
environment of every subsequent `RUN`/`COPY`, so changing any declared
`--build-arg` invalidates subsequent execution steps even if unreferenced.
This over-invalidates relative to Docker (which tracks reference), and is
recorded as an accepted tradeoff below.

### On-disk layout

All under the existing rootfs cache root (`local_paths.rootfsCacheRootPath`):

```
cas/rootfs/blake3/indexes/<index_digest>.json      (existing) disk index
cas/rootfs/blake3/objects/<chunk_digest>.chunk      (existing) CAS object
cas/rootfs/blake3/complete/<index_digest>.complete  (existing) completeness stamp
build/steps/<step_key>.json                         build step record
build/context-stat-cache-v1.json                    context content-digest memo
build/context-disks/<context_disk_digest>.ext4      cached read-only COPY disk
build/context-disks/<context_disk_digest>.ext4.complete  context disk completeness stamp
refs/local/<sha256>.json                            (existing) final ref
<image_cache_key>.json                              (existing) image metadata
```

Intermediates are input-addressed by their step key, but their artifacts are
normal rootfs CAS indexes. The step record is not restore authority; it is a
local memo from deterministic inputs to a child `index_digest`. A cache hit
requires the child index to parse, validate against the rootfs descriptor, and
have the already-published completeness stamp. v7 does not repair a missing
stamp during lookup: missing or malformed indexes, missing complete stamps, or
bad records are misses. GC continues to parse older records conservatively and
may retain their complete content, but v6 records cannot hit v7 keys.

Step record, written or replaced atomically (temp + rename) only after
`snapshotIndex()` has published the index/chunks and the complete stamp exists:

```json
{
  "kind": "sporevm-build-step-v1",
  "builder_version": "sporevm-build-v7",
  "platform": {"os": "linux", "arch": "arm64"},
  "step_key": "…",
  "parent_index_digest": "…",
  "child_index_digest": "…",
  "rootfs_storage": {
    "kind": "chunked-ext4-rootfs-v0",
    "device": {"kind": "virtio-mmio", "role": "rootfs", "virtio_device_id": 2, "mmio_slot": 1},
    "logical_size": 17179869184,
    "chunk_size": 65536,
    "hash_algorithm": "blake3",
    "index_digest": "blake3:…",
    "base_identity": "blake3:…",
    "object_namespace": "rootfs/blake3"
  },
  "instruction_kind": "RUN",
  "instruction": "RUN apt-get update && …",
  "input_digest": "",
  "env_digest": "…",
  "workdir": "/app",
  "network_mode": "spore",
  "executor_identity": "blake3:…",
  "created_unix": 0
}
```

Capacity preparation uses the same bounded parser, atomic writer, CAS objects,
completeness stamps, and GC roots rather than a second cache subsystem:

```json
{
  "kind": "sporevm-build-step-v1",
  "builder_version": "sporevm-build-v7",
  "platform": {"os": "linux", "arch": "arm64"},
  "step_key": "…",
  "parent_index_digest": "blake3:…",
  "child_index_digest": "blake3:…",
  "instruction_kind": "PREPARE",
  "instruction": "PREPARE",
  "input_digest": "",
  "env_digest": "",
  "workdir": "",
  "exact_target": 17179869184,
  "producer_identity": "blake3:…",
  "executor_identity": "",
  "rootfs_storage": {
    "kind": "chunked-ext4-rootfs-v0",
    "device": {"kind": "virtio-mmio", "role": "rootfs", "virtio_device_id": 2, "mmio_slot": 1},
    "logical_size": 17179869184,
    "chunk_size": 65536,
    "hash_algorithm": "blake3",
    "index_digest": "blake3:…",
    "base_identity": "blake3:…",
    "object_namespace": "rootfs/blake3"
  },
  "created_unix": 0
}
```

Final rootfs identities are **recorded outcomes, not recomputed promises**. Guest
writes (inode allocation, timestamps) are not deterministic, so the same step
key can map to different rootfs indexes on different machines or after a cache
wipe. A successful `--no-cache` execution may therefore replace an existing
step record for the same key with its newly produced child index. The step
record is a derived mapping; rootfs CAS indexes and objects remain immutable.
That is the same model Docker uses: cache keys are deterministic, the artifact
identity is whatever the execution produced. Nothing downstream assumes
reproducibility of the ext4 bytes.

Context hashing also maintains
`build/context-stat-cache-v1.json` under the same local cache root. The JSON
file has `kind: "sporevm-build-context-stat-cache-v1"`, `max_records`,
`eviction: "least-recently-seen stat tuple"`, and `records` containing
`path`, `size`, `mtime_ns`, `ctime_ns`, `inode`, `digest`, and
`last_seen_unix_ns`. The lookup key is `(absolute path, size, mtime
nanoseconds, ctime nanoseconds, inode)`. A hit reuses only the per-file BLAKE3
content digest; the overall COPY/context input digest is still rebuilt from the
same sorted entry fields a cold hash would use.
Missing, corrupt, oversized, or stale stat-cache entries fall back to reading
and hashing file content, and the build proceeds. The file is capped at
131,072 records and 32 MiB; save eviction keeps the most recently seen stat
tuples.

### Final image identity

The final image's rootfs identity is the last step's `index_digest`, but the
published local image identity is a digest over that `index_digest` plus the
canonical final image config JSON. That keeps two config-only variants with the
same rootfs from sharing a resolved image ref or metadata path. `spore build`
publishes the image digest through the same local-ref path as
`spore rootfs import-tar`, with image config metadata attached for `Env`,
`Cmd`, and `WorkingDir`; the exact digest construction is documented in
`docs/spore-format.md`. The cache object is the existing `RootFSMetadata`
shape; it does not add a new kind or format contract.

```json
{
  "builder_version": "sporevm-rootfs-v6",
  "ext4_writer": "built-index",
  "image_ref": "local/app:dev",
  "resolved_image_ref": "local/app@blake3:…",
  "image_manifest_digest": "blake3:…",
  "platform": {"os": "linux", "arch": "arm64"},
  "config_digest": "blake3:…",
  "config": {"config": {"Env": ["A=B"], "Cmd": ["/bin/true"], "WorkingDir": "/app"}},
  "layers": [],
  "deterministic": false,
  "ext4_uuid": "",
  "ext4_hash_seed": "",
  "rootfs_path": "",
  "rootfs_size": 17179869184,
  "rootfs_storage": {
    "kind": "chunked-ext4-rootfs-v0",
    "device": {"kind": "virtio-mmio", "role": "rootfs", "virtio_device_id": 2, "mmio_slot": 1},
    "logical_size": 17179869184,
    "chunk_size": 65536,
    "hash_algorithm": "blake3",
    "index_digest": "blake3:…",
    "base_identity": "blake3:…",
    "object_namespace": "rootfs/blake3"
  }
}
```

Publication follows the import path:

1. verify the final `index_digest` and complete stamp;
2. write `RootFSMetadata`-compatible image metadata carrying the rootfs storage
   descriptor and final config so `readCachedImageRunConfig` picks it up at run
   time;
3. compute the image digest from rootfs identity plus config and update the
   mutable tag with that resolved ref.

Result: `spore run --image local/buildkite-spore:dev` works today's way, and
`--save` records portable chunked storage immediately because the cache
metadata already carries the rootfs storage index.

## RUN Execution And Snapshot

Uncached steps execute in **one persistent build VM per build**, not one VM per
step. A preparation miss and all remaining RUN/COPY/WORKDIR instructions share
that VM. A preparation hit becomes the normal Dockerfile cache parent, so a
later Dockerfile miss boots directly from the prepared child with no resize.
Checkpoints freeze the filesystem, drain virtio-blk, seal only changed chunks,
and enumerate one canonical full rootfs CAS index.

Session lifecycle:

1. Before the first executor-backed instruction, compute the absolute target
   `max(FROM.logical_size, 16 GiB)`. If no growth is needed, continue directly.
   Otherwise resolve the v7 `PREPARE` key. A valid hit supplies the prepared
   child index before any Dockerfile key is calculated, including under
   `--no-cache`.
2. On a `PREPARE` miss, open the immutable FROM index as the
   `ChunkMappedDisk` parent and attach build-owned writable overlay state. Grow
   the disk to the exact target by appending authoritative clean-zero chunks;
   the sparse fd and verified parent index make those zeroes storage truth, so
   snapshotting does not read, hash, or allocate payload for the untouched
   tail.
3. Boot via the existing run stack with an internal rootfs-growth profile. The
   host marks the VM non-resumable and transiently offers
   `VIRTIO_BLK_F_WRITE_ZEROES` only on the root block device. Before the first
   writable mount, the managed initrd opens `/dev/vda` read-only and rejects
   journal presence, recovery or journal-device flags, filesystem error or
   orphan state, a nonzero legacy orphan head, and pending orphan cleanup; it
   then mounts the rootfs read-write. The shared virtio handler validates one
   bounded range and maps accepted zeroing directly to
   `ChunkMappedDisk.zeroRange`; the growth-only feature never enters a portable
   manifest or restored transport state.
4. The host sends the strict two-field `spore-rootfs-grow-v1` request. The
   managed initrd re-reads and validates the source state before any resize
   mutation, reads the exact device geometry, calls `EXT4_IOC_RESIZE_FS` on the
   mounted rootfs, `syncfs`es, and validates the source state again. It requires
   the feature-aware ext4 superblock block count to increase and reach the
   target within less than one block group. The host independently validates
   the exact response against the same invariants. No selected-image shell or
   e2fsprogs utility participates.
5. Freeze the prepared filesystem, quiesce virtio-blk, seal the changed
   metadata chunks, emit the canonical logical index, publish the completeness
   stamp, and write the
   typed `PREPARE` record last. Thaw without advancing the Dockerfile step
   index, install the prepared child as the live `ChunkMappedDisk` baseline,
   and continue step zero in the same VM. A failed grow, freeze, snapshot,
   stamp, or record publication executes no Dockerfile step and publishes no
   destination ref.
6. For an ordinary Dockerfile executor miss, use the prepared parent through
   the same internal writable-rootfs mode, without the growth-only feature or
   control request. Continue the VM already live after a preparation miss, or
   boot the prepared child once after a preparation hit. The host drives the
   existing initrd agent over bounded `spore_stream_v1` requests:
   - `RUN`: host sends a fixed-shape `spore-build-run-v1` request with the
     step's effective env, workdir, and command length, then sends the command
     text as a length-prefixed payload capped at 64 KiB. The driver runs
     `/bin/sh -c` as root (Docker parity: `-c`, not the `-lc` that
     `spore run`'s shell mode uses), streams output through, and reports the
     exit code. Network per `--network` for the whole session.
   - `COPY`: before boot, the host emits the resolved context entries needed
     by executed COPY steps into a cached read-only ext4 context disk and
     attaches it as an additional virtio-blk device. Per step, the host sends
     one or more fixed-shape `spore-build-copy-v2` control requests naming the
     source subtree on `/mnt/build-context`, destination, source kind, and
     bounded entry count. The agent recursively copies from the mounted
     context disk into `/mnt/rootfs` using the confined destination resolver
     (see COPY Semantics).
   - `CHECKPOINT`: agent handles `fsfreeze-v1` after the step exits;
     the VMM drains/flushes pending virtio-blk writes, the host calls
     `ChunkMappedDisk.snapshotIndex()` into the rootfs CAS, writes the
     complete stamp, writes the step record with the child `index_digest`, and
     then sends `fsthaw-v1`. Because all
     step processes have already exited and the filesystem is frozen at
     snapshot time, checkpoints are clean images, not crash-consistent guesses
     — this matters because the rootfs ext4 profile has no journal. Publishing
     the stamp and step record before thaw is intentional: a thaw failure
     fails the active build, but the frozen snapshot is complete and remains a
     valid resume point for the next build. The drain requirement belongs to
     the existing virtio-blk write path (`src/virtio/blk.zig`).
   - `DONE`: driver exits; guest shuts down cleanly.
7. A non-zero step exit fails the build with the exit code and the
   instruction; the session is torn down, live overlay state is deleted, and
   no record is written for the failed step. Checkpoints of earlier successful
   steps remain valid — the retry resumes from the last recorded
   `index_digest`.
8. After the last step's snapshot and shutdown: publish the last
   `index_digest` under the requested local image ref. There is no final
   full-image hash or flat install pass.

Overhead after a prepared-base hit, on top of the commands themselves, is one
boot for an uncached suffix, sync+freeze, dirty-only sealing plus full-index
emission per changed step, and local-ref publication. A first preparation miss
adds the direct kernel ioctl and one metadata-sealing/full-index checkpoint
inside that same boot. Unrelated Dockerfiles and
repeated `--no-cache` builds reuse the `PREPARE` child and pay no growth path.
There is no tar export, full-image hash, flat materialization, guest utility
launch, or recursively increasing capacity.

Historical diagnostic only: the pre-v7 tiny Alpine fixture measured about
4.17s cold with the former combined growth path and about 0.36s when supplied a
pre-grown 10 GiB base through the now-removed hidden override. That roughly
3.8s delta motivated separating preparation and replacing guest `resize2fs`;
it is evidence about the superseded implementation, not a v7 performance
result or a supported configuration path.

De-risk fallback, recorded not planned: if persistent in-guest orchestration
regresses, the degenerate mode is one boot-snapshot-shutdown cycle per step
(same cache records and `index_digest` outcomes, N boots). It costs one boot
per changed step instead of per build; the cache model is identical in both
modes.

The guest sees the writable rootfs plus, when COPY steps execute, a mounted
read-only context disk (`spore_rootfs=1 spore_rootfs_rw=1
spore_build_context=1`). The initrd agent now provides the build control verbs
(`spore-rootfs-grow-v1`, `fsfreeze-v1`, `fsthaw-v1`, `spore-build-run-v1`,
`spore-build-copy-v2`); the target base must provide `/bin/sh` for RUN and
nothing for capacity preparation. A missing RUN shell fails closed through the
step's captured output.

## COPY Semantics

`COPY` goes **through the guest**, inside the same persistent build-VM
session as `RUN`, rather than host-side ext4 surgery:

1. On the host, resolve sources against the context with the same walker used
   by hashing. It rejects absolute and `..` paths, opens every parent component
   fd-relatively without following symlinks, preserves a final symlink as COPY
   data, and applies `.dockerignore`. Executor misses stream each matched file
   once into a private sparse spool while hashing those same bytes; modes and
   symlink targets are captured by value. The immutable captured entries are
   both the cache input digest and the context-disk source.
2. Map Docker destinations on the host: directory sources copy contents,
   multiple sources require a `/`-terminated destination, relative destinations
   resolve against `WORKDIR`, and guest paths containing `..` fail closed.
3. Emit or reuse the cached read-only ext4 context disk from the captured
   entries. Each COPY step occupies its own short transport namespace, so a
   later overlapping COPY cannot add files beneath an earlier recursive source.
   The disk digest is derived from the sorted transport paths, kinds, modes,
   sizes, file content digests, and symlink targets; it is transport identity
   only and does not enter step-cache semantics. Unchanged contexts
   reuse the disk image only when its completion sidecar is present and valid;
   the sidecar is published after full disk emission. Changed contexts still
   mostly dedupe through the rootfs CAS chunks emitted by the native ext4
   writer.
4. Send fixed-shape `spore-build-copy-v2` control requests. Each request names
   the context-disk source subtree, destination, source kind, `dest_is_dir`,
   and entry count. The guest enforces path and entry-count bounds, then
   recursively copies from `/mnt/build-context`. Destination paths are resolved
   relative to an fd for `/mnt/rootfs` with `openat2(RESOLVE_IN_ROOT |
   RESOLVE_NO_MAGICLINKS)`, falling back on kernels without `openat2` to a
   confined manual component walk that keeps symlink targets rooted in the
   rootfs. Final-component symlinks are followed under the same confined
   resolution, so file entries write through them, directory entries merge
   through symlinked directories, and dangling file symlink targets are created
   inside the rootfs. It applies entries with root ownership, parent creation,
   directory merge, file overwrite, and symlink preservation.
5. Checkpoint exactly as RUN does (freeze, dirty-only sealing plus full-index
   emission, complete stamp, step record, thaw).

Corollary: COPY does not require `tar` in the base image, does not add a tar
or custom entry-stream parser to the initrd agent, and keeps guest memory usage
bounded by per-entry copy buffers rather than total COPY size. Hardlinks,
xattrs, `--chown`, `--chmod`, `--from`, `--link`, `ADD`, and multi-stage builds
remain unsupported and fail closed.

Why the guest and not `debugfs` writes or host staging: a real Linux kernel
applies ownership, modes, symlinks, and directory merge behavior natively and
correctly, with no root requirement on the host and no macOS case-sensitivity
or metadata hazards. `debugfs -w` scripting for arbitrary tree merges
(overwrite-vs-merge, unlink-before-write, hardlinks) is a large correctness
surface for no architectural payoff. With the persistent session the guest
boot is already amortized across the whole build, so COPY's marginal cost is
context-disk emission or reuse, in-guest disk-to-disk copy, and one
freeze/snapshot checkpoint. Host-side COPY (writing directly into the rootfs
without the guest) stays a documented follow-up for the case where a COPY is
the *only* uncached step; it is deferred because it would need a separate
proof that host-side ext4 mutation preserves Docker merge, symlink,
ownership, and mode semantics without reintroducing an import-style
correctness surface.

Docker semantic contract, tested explicitly:

- `COPY dir/ /dest/` copies the *contents* of `dir` into `/dest`.
- Multiple sources require a `/`-terminated destination.
- Relative destinations resolve against the current `WORKDIR`.
- Copied entries are owned `0:0`; file modes come from the context.
- Destination symlinks are followed under confined rootfs resolution: file
  entries write through final symlinks, directory entries merge through
  symlinked directories, and absolute symlink targets re-root inside the
  rootfs.
- Wildcards (`*`, `?`) match with Go-filepath rules per Docker; first
  implementation supports literal paths and `*` globs, rejects the rest.

## Wrapper Changes (`buildkite-sporevm/bin/buildkite-spore`)

`build_rootfs` collapses from four phases to one:

```bash
# before: buildx build --output type=tar + spore rootfs import-tar
# after:
"${spore_bin}" build \
  -t "${image}" \
  --platform "${platform}" \
  --build-context "base=oci-layout://${base_oci_dir}" \
  "${context}"
```

Kept as-is: `ensure_local_images` (the preliminary `docker build --target ci`
and Postgres builds), `ensure_base_oci` (docker-save + index patch, cached by
image ID — the patched layout must import cleanly through `importOciLayout`,
verified in M1), dependency tar caching, DynamoDB download.

Removed: the buildx builder (`ensure_builder`), `tar_output` handling, the
`import-tar` call.

Changed: `prepare_context` currently does `rm -rf` + full ~573M copy every
run, which would dominate the cached path. It switches to `cp -c` (APFS
clonefile) and/or skips recreation when source markers (dep tar `.id` files,
dynamodb cache, repo files) are unchanged. The context stays on disk between
runs so `spore build` can hash it.

Cached `start` then costs: docker image inspects (~1s) + context freshness
check (~1s) + `spore build` cache hit (<1s) + `spore rootfs resolve` — low
single-digit seconds end to end, with the BuildKit tar export removed.

## Safety Model And Invariants

- The Dockerfile parser and context walker are new parsers of user-influenced
  input. Per `SECURITY.md`, they ship with fuzz targets in the same change
  (M1 for the parser; M2 COPY keeps context-disk emission on the same resolver
  path and replaces the guest entry-stream parser with fixed-shape control
  requests plus the guest kernel's ext4 parser for a host-produced read-only
  disk).
- `RUN` executes arbitrary user commands — inside the SporeVM guest, which is
  the existing isolation boundary. The builder adds no new device type. It may
  attach one read-only virtio-blk context disk and, only in a non-resumable
  growth session, offer WRITE_ZEROES on the existing root device. The shared
  virtio parser bounds and prevalidates the complete request before mutation;
  backend failure poisons the unpublished mutable head so it cannot be
  snapshotted or forked.
- `spore-rootfs-grow-v1` is bounded attacker-influenced control input. The
  managed initrd accepts exactly one type and one nonempty bounded session id,
  rejecting duplicate, unknown, trailing, or embedded-NUL input. It validates
  the journal-less source state before writable mount, revalidates it before
  and after the ioctl, and checks authoritative pre/post ext4 geometry; the host
  validates its exact response against the target and one-group bound. Malformed
  input, unsupported ext4 state or geometry, or an ioctl/block error aborts
  before PREPARE, Dockerfile records, or the destination ref are published.
- Step records under `build/steps/` are trusted local build metadata — same
  trust level as the cache directory that holds them — and never leave
  `build/`. The rootfs artifacts they name are normal rootfs CAS
  indexes/objects. Records that reference missing or malformed indexes, or
  indexes without a complete stamp, are treated as misses and are never
  repaired in place.
- COPY source resolution must not escape the context directory: reject `..`
  traversal and absolute sources after substitution, and reject symlinks in
  every intermediate source-path component. A final source symlink remains a
  symlink entry and is never followed by context discovery.
- Executor-side COPY hashing and context-disk emission must consume the same
  immutable sparse-spool slices. No emitted file may reopen the live build
  context, and each COPY request sees only its per-step transport namespace.
- Built-image metadata must not be mistakable for portable OCI provenance: it
  uses the existing `RootFSMetadata` cache shape with `ext4_writer:
  built-index`, `layers: []`, and explicit `rootfs_storage` pointing at the
  final `index_digest`. This is the local rootfs metadata field name; portable
  spore manifests continue to use `rootfs.storage`.
- Portable machine state and spore format are untouched. Growth-only feature
  negotiation is transient and capture/restore rejects it; no manifest format
  or device-ordering change is introduced.

## Delivery Strategy

### M1 — Parser, cache resolution, fully cached path

`spore build` exists without VM execution. The parser handles the full subset
grammar and fails closed (with tests asserting exact error text) on everything
outside it. `FROM` resolves `--build-context oci-layout://` (through
`importOciLayout`, including the wrapper's patched docker-save layout) and
local refs. The context walker applies `.dockerignore`, rejects escapes, and
computes deterministic COPY input digests. The cache walker derives every step
key from parent `index_digest`, instruction, input digests, env, workdir, and
platform; a fully cached build verifies the final record, index, and complete
stamp, updates the local ref, and exits. On the first cache miss for `RUN` or
`COPY`, M1 fails closed with "cache miss requires build executor" rather than
falling back to BuildKit or doing partial work.

Implementation note (2026-07-09): the first M1 implementation slice adds the
`spore build` CLI, Dockerfile subset parser, `.dockerignore`/COPY context
hashing, local step-cache read/write helpers, fully cached build resolution, and
indexed local image publication/run resolution. M2 starts at executor-owned
cache misses; it should write the same `sporevm-build-step-v1` records after
each dirty-only sealing/full-index checkpoint.

Implementation note (2026-07-10): COPY discovery opens the canonical context
root once and walks literal-source parents and glob parents one component at a
time with no-follow directory handles. This rejects intermediate symlinks while
retaining Docker's final-symlink preservation semantics.

Definition of done:
- Dockerfile parser unit tests cover the supported subset and exact
  fail-closed errors for unsupported features.
- Parser and `.dockerignore`/context-ingestion fuzz targets are in-tree in the
  same change as the new parsers.
- A fully cached fixture build resolves the final `index_digest`, verifies the
  complete stamp, updates the local ref, and exits in <1s without booting a VM.
- A metadata-only Dockerfile (`FROM`/`ENV`/`ARG`/`CMD`) publishes a runnable
  image by reusing the base `index_digest`; a second invocation is a full cache
  hit in <1s. `WORKDIR` is covered by the M2 filesystem-step smoke.
- `spore run --image local/x:dev -- /bin/true` boots the published result.
- `mise run build` and `zig build test --summary all` pass.

Ceiling proven: cached build resolution and ref publication <1s; base import
cost paid once.

### M2 — RUN/COPY via the persistent build-VM session

The session executor: open the deepest cached index through `ChunkMappedDisk`
with build-owned overlay state, rw rootfs boot behind the hypervisor-neutral
disk interface, bounded agent requests over `spore_stream_v1`, length-prefixed
64 KiB-capped `/bin/sh -c` RUN payloads with env/workdir/network, cached
read-only ext4 context disks for COPY, fixed-shape `spore-build-copy-v2`
control requests, freeze/snapshot/stamp/record/thaw checkpointing (including
the virtio-blk drain), complete-stamp publication, streamed step output, and
non-zero-exit cleanup.
Every executed instruction produces exactly one child `index_digest` through
`ChunkMappedDisk.snapshotIndex()`; no flat checkpoint and no full-image hash
exist in this path.

Definition of done:
- `FROM base` + `RUN apt-get update && apt-get install -y …` builds against
  the real Buildkite base OCI layout; the result boots; installed packages are
  present.
- Mixed RUN/COPY Dockerfiles execute in one guest boot with a checkpoint
  between each executed step.
- Rebuild without changes: cache hit, no VM boot, <1s.
- Changing a later RUN string or copied file resumes from the deepest cached
  `index_digest` — one boot, only the changed step and following steps
  re-execute.
- A failing RUN reports the exit code and instruction, leaves no step record
  for the failed step, leaves no live temp files; earlier checkpoints remain
  usable.
- A checkpoint taken mid-build boots and fsck's clean when opened from its
  published `index_digest` (freeze correctness smoke).
- fixed 16 GiB capacity policy, direct-ioctl PREPARE, transient WRITE_ZEROES,
  and prepared-base reuse are exercised by the gated build smoke before
  Dockerfile steps execute.

Ceiling proven: a first uncached RUN/COPY build = one boot containing direct
capacity preparation + step time + dirty-only sealing/full-index checkpoints; a prepared uncached
build = one boot + step time + snapshots; cached build ≈ 0.

Implementation note (2026-07-09, RUN slice): the executor now starts at the
first uncached `RUN`, opens the parent rootfs through the normal writable
`ChunkMappedDisk` run path, boots one build VM, and drives each remaining `RUN`
over `spore_stream_v1` with the step env/workdir applied to `/bin/sh -c`.
After each successful RUN the guest agent handles `fsfreeze-v1`, the host takes
a rootfs-only `ChunkMappedDisk` snapshot after the existing virtio-blk
quiescence check, writes the completeness stamp, writes the
`sporevm-build-step-v1` record through `step_cache.writeRecord`, then sends
`fsthaw-v1` before continuing. This publish-before-thaw ordering is
intentional: if thaw fails, the active build fails but the completed frozen
snapshot remains a valid cache resume point. Failed RUNs report the
instruction, exit code, and captured output without writing the failed step
record. The slice also fixes
`spore run --image` for indexed rootfs images so build-published images pass
`spore_rootfs=1` even when there is no flat rootfs path.
The build VM memory remains a fixed 2 GiB default. The original Buildkite
Dockerfile's apt and Docker installation RUN completed at that size. Add a
`spore build` option only when a build-time workload demonstrates that 2 GiB
is insufficient.

Implementation note (2026-07-10, RUN shell expansion): shell-form RUN is now
opaque to Dockerfile variable substitution and reaches guest `/bin/sh -c`
unchanged. ARG and ENV values are exported through the step environment, so
the shell owns quoting, command substitution, special parameters, and
variables created earlier in the same command. The build cache version moved
to `sporevm-build-v2` to prevent reuse of checkpoints created under the old
host-substitution behavior.

Implementation note (2026-07-10, cache execution identity): RUN step records
now key the typed `spore`/`none` network mode, and ENV/ARG state uses ordered,
length-framed typed records rather than a sorted newline-delimited projection.
The build cache version moved to `sporevm-build-v3`; v2 records are retained as
GC roots but cannot be reused by the corrected lookup path.

Implementation note (2026-07-10, immutable COPY capture): executor-side COPY
opens source components fd-relatively without following symlinks, streams file
bytes once through BLAKE3 into a private 0600 sparse spool, verifies the opened
file did not change during capture, and seals the spool before ext4 emission.
Context-disk entries reference only captured spool slices or by-value metadata;
the original host paths are never reopened. Per-step `sN/` namespaces prevent
overlapping directory and glob requests from observing another step's unioned
entries. The spool is deleted after context-disk emission or on every error.
The build cache version moved to `sporevm-build-v4` so checkpoints created by
the old split hash/emission path cannot be reused; earlier records remain GC
roots only.

Implementation note (2026-07-10, WORKDIR and COPY filesystem semantics):
`WORKDIR` is now a cacheable filesystem step, not metadata-only state. The
guest creates its normalized absolute path through the same rootfs-confined
resolution used by COPY, snapshots it, and only then applies it to later RUN
and relative COPY instructions. COPY resolves an existing destination
directory at apply time even when the Dockerfile destination has no trailing
slash, and copied files/directories are explicitly reset to root ownership
when they replace existing entries. The VM smoke requires WORKDIR creation
before the following RUN, exercises a no-slash existing-directory COPY, and
overwrites a deliberately non-root file. The build cache version moved to
`sporevm-build-v6`; v5 records remain GC roots but cannot represent the new
WORKDIR checkpoint or corrected ownership outcomes.

Implementation note (2026-07-10, RUN descendant cleanup): every build RUN
shell is moved into a dedicated cgroup v2 leaf before its start gate opens.
After the direct shell exits, the guest writes `cgroup.kill`, waits for the
leaf to become empty, then repeatedly kills and reaps every remaining process
in the dedicated build guest through a procfs directory descriptor retained
by PID 1 from boot. RUN processes cannot replace that descriptor or inherit it
across exec. The agent removes the leaf and sends the SPIO exit frame only
after the sweep is empty, allowing the host to freeze and checkpoint the
rootfs. This covers descendants that detach into a new session, process group,
or ancestor cgroup, even if they alter their mount namespace or overmount
`/proc`. The bounded `/proc/<pid>/stat` classifier uses the kernel-owned
`PF_KTHREAD` flag and is unit/fuzz covered for RUN-controlled task names.
Setup, kill, drain, or removal failures return exit 125 and prevent a
step-cache record. The VM-backed smoke moves a detached delayed writer out of
the RUN cgroup and proves it cannot mutate the next step. The build cache
version moved to
`sporevm-build-v5`; older records remain GC roots but are not reusable because
they may capture filesystem state that raced a surviving RUN descendant.

Superseded implementation note (2026-07-10, v6 stable grow target): v6 anchored
the former additive/doubling target to `FROM` and included that target in the
first Dockerfile step key. This stopped recursive growth within a cached chain
but still coupled routine filesystem resize to the first executor miss and
required guest `resize2fs`. Build cache v7 replaces that mechanism completely:
the idempotent automatic target is `max(FROM.logical_size, 16 GiB)`, preparation
has its own parent/target/producer key, and Dockerfile step keys contain no
growth field. v6 records remain conservative GC roots but cannot hit v7 keys.

Implementation note (2026-07-11, v7 capacity preparation): supported
journal-less compact FROM images append clean known-zero coverage without
physical preallocation. The
non-resumable growth VM temporarily negotiates WRITE_ZEROES, then the managed
initrd handles `spore-rootfs-grow-v1` with `EXT4_IOC_RESIZE_FS` and bounded
geometry validation. Freeze → metadata-only sealing plus canonical full-index
emission → completeness stamp →
`PREPARE` record → thaw occurs before Dockerfile step zero, and the same VM
continues on a miss. A hit supplies the normal Dockerfile parent even under
`--no-cache`. The hidden growth override was removed; above-cap images remain
byte-exact and are never rounded or doubled.

Implementation note (2026-07-10, checkpoint control latency): repeated
freeze/thaw requests used fixed session identities, which reused the same
derived host vsock ports before the preceding connection had retired and
introduced an approximately 8.2-second stall between executed steps. Build
streams now receive monotonically sequenced dynamic host ports, and checkpoint
session identities include the step number. The VM smoke records the slowest
freeze/thaw control and requires it to stay below two seconds; the corrected
run completed these controls in milliseconds. Snapshot cost remains measured
separately, including the PREPARE checkpoint after disk growth.

Implementation note (2026-07-09, COPY/context-disk slice): the executor step
list is now a tagged RUN/COPY sequence, so the first uncached COPY enters the
same persistent VM path as RUN. COPY write-side keys use the same `StepInput`
fields the M1 resolver reads: parent index, `"COPY"`, raw instruction,
build-context input digest, environment digest, and workdir. The same resolved
context walk feeds both the COPY input digest and the context-disk builder; a
cold full hash and a warm stat-cache hit path must produce byte-identical step
keys. The host emits or reuses a cached read-only ext4 image under
`build/context-disks/`, attaches it as a second virtio-blk instance at boot,
and sends bounded `spore-build-copy-v2` control messages naming source,
destination, kind, destination-directory behavior, and entry count. The guest
agent validates the request shape and count, mounts the context disk read-only,
and confines all destination apply-path resolution to `/mnt/rootfs` while
preserving Docker-style rootfs-internal and final-component symlink traversal.
COPY checkpoints use the same freeze → snapshot → complete stamp → step
record → thaw ordering as RUN; if any COPY request in a step fails, the build
fails before snapshot promotion for that step. Session start uses the
prepared parent produced by the v7 policy above; COPY keys never carry a grow
target, and there is no capacity override. A manual
Docker-vs-Spore metadata oracle lives at
`scripts/spore-build-copy-oracle.sh`.

Implementation note (2026-07-10, GC coordination): after `FROM` resolution,
the build holds the rootfs-cache coarse lock across step-cache lookup and VM
execution. Lazy runtime-disk setup borrows that live, root-bound guard while it
publishes the baseline lease, instead of trying to lock the same cache again.
The build retains ownership through final metadata/ref publication. Valid
`sporevm-build-step-v1` records are GC roots for their child index and objects;
known incomplete records are ignored as cache misses, and unknown future record
kinds retain the CAS conservatively. Record retention/pruning remains
post-core hardening work.

Historical implementation note (2026-07-10, original pre-v7 workload proof):
build RUN requests refresh the guest realtime clock before execution, and
mounted rootfs images
receive devpts plus the standard `/dev/fd`, stdio, and `ptmx` links. Named image
creation accepts the immutable rootfs metadata already recorded by the
lifecycle parent. The original committed `buildkite-sporevm` Dockerfile context
at `ad89671` completed its forced `--no-cache` build against the existing
BuildKit-produced base OCI in 42.59s with no manual disk-headroom override; its
long apt transaction and Docker package installation both completed. This is
retained as workload-compatibility history, not current capacity-path timing.
Repeating an input key after a forced execution now atomically replaces only
the derived step mapping, while rootfs CAS indexes and objects retain immutable
publication.

Post-merge acceptance on `0a99933` rebuilt the same original Dockerfile in
148.78s cold, 9.87s warm, and 7.31s after changing one context file. The image
booted, `/bin/true` and Ruby/RSpec probes passed, and wrapper readiness took
36.23s. Later runtime fixes proved the application path: one-shot `bin/setup`
completed in 709.87s on `d8db64a`; named `bin/setup` completed in 1081.69s on
`8790d6a` while streaming 45,495 bytes without truncation; and
`spec/middleware/admin/developer_tools_guard_spec.rb` passed 11 examples with
zero failures in 27.80s. All runs ended with no VM left behind.

Remaining M2 completion work: record the full Docker-vs-Spore file-tree
equivalence result and the exact trailing-COPY invalidation behavior for the
real workload.

Definition of done:
- The full `buildkite-sporevm` Dockerfile (`FROM base`, apt RUN, five COPYs,
  chmod RUN, CMD) builds end to end through Spore after the base OCI layout is
  prepared separately.
- File-tree diff of the built rootfs against the docker-buildx-built rootfs
  for the same inputs shows only expected divergence (mtimes, `/etc/resolv.conf`
  placeholder, ext4 identity) — paths, modes, sizes, symlink targets, uid/gid
  match.
- Touching one context file invalidates exactly the COPY that matched it and
  later steps.
- COPY semantics test matrix passes (dir-contents, multi-source, relative
  dest, overwrite/merge, symlink, empty dir, mode preservation, exec bit).

Ceiling proven: cached full build (parse + stat-only context hash + lookups +
ref refresh) ≤2s warm-stat; uncached COPY ≈ context-disk emit/reuse +
guest disk-to-disk apply plus one freeze/dirty-only sealing and full-index checkpoint, with boot
amortized per build.

### M3 — Wrapper integration and benchmark

The original wrapper Dockerfile now builds and runs through Spore, but the
repeatable integration still belongs in `buildkite-sporevm`. Replace its final
buildx/import-tar seam with `spore build`, keep base OCI preparation explicit,
keep any generated application context incremental and clonefile-based, and add
one smoke command that performs build -> named start -> setup -> known-good
RSpec -> stop with guaranteed cleanup and preserved failure logs. Add the
profiling phases below and record before/after results in `docs/benchmarks.md`.

Definition of done:
- `buildkite-spore build` (cached) completes in single-digit seconds wall
  clock, from the current ~30s warm baseline, with `spore build` itself <1s.
- `buildkite-spore start` boots the built image, `setup-spore` reaches
  `/tmp/sporevm-buildkite/ready`, and `buildkite-spore rspec <known-good
  spec>` passes. This behavior is proven manually; the milestone completes
  when the repeatable smoke path lands in `buildkite-sporevm`.
- Uncached full build wall clock recorded; target ≤ current uncached path.
- Benchmark script lives in `scripts/` and runs identically by hand and in CI
  where hardware allows.

### M4 — Ergonomics and hardening (follow-ups, ordered by need)

- Define an explicit retention policy for obsolete step records, then retire
  them before root-aware cache GC reclaims their CAS indexes and objects.
- Host-side COPY fast path (apply a COPY without booting the session when it
  is the only uncached step), after a separate design proves it can stay out
  of the import hot path.
- Registry `FROM` refs; exec-form `RUN`; `--chown`/`--chmod` on COPY if a
  real consumer appears.
- `--builder=buildkit` convenience fallback that shells out to buildx +
  import-tar, if the fail-closed hint proves annoying in practice.

## Verification

Tests:

- Parser: unit tests per instruction, substitution, continuations, comments;
  exact fail-closed error text for each unsupported feature; fuzz target.
- Step keys: golden tests that keys are stable across runs and change exactly
  when the spec says (each invalidation rule in the Cache Model section gets a
  test).
- Step cache: v7 PREPARE keys vary with parent, exact target, and producer;
  Dockerfile keys use the prepared child and contain no growth target; records
  survive process restart; missing artifact ⇒ miss; corrupted record ⇒ miss;
  missing complete stamp ⇒ miss without repair; atomic write leaves no partial
  record after simulated failure between snapshot publication and record write;
  v6 records remain GC roots but are cache misses.
- Executor: exit-code propagation, env/workdir application, network
  on/off, idempotent 16 GiB policy, already-large preservation, clean-zero
  sparse growth, direct resize response validation, same-VM PREPARE checkpoint,
  `--no-cache` PREPARE reuse, and failure cleanup before any Dockerfile step or
  destination-ref publication.
- COPY matrix listed above, plus context-escape rejection tests.
- Large COPY: generated sparse fixture with aggregate payload above guest RAM
  succeeds through context-disk apply and records emitted/reused diagnostics.
- End-to-end: small fixture base (tiny OCI layout already used by import
  tests) through FROM+RUN+COPY+CMD, then `spore run` smoke; the real
  `buildkite-sporevm` path as the M3 hardware smoke.
- Equivalence: scripted file-tree diff (path, type, mode, uid/gid, size,
  symlink target) between spore-built and buildx-built rootfs.

Instrumentation (extends the existing `SPOREVM_ROOTFS_BUILD_PROFILE`
convention, same output shape):

```
spore build profile: phase=parse ms=…
spore build profile: phase=base_resolve ms=…
spore build profile: phase=context_hash ms=…
spore build profile: phase=context_disk cache=emitted|reused ms=…
spore build profile: phase=prepare cache=hit|miss|not-needed target_bytes=…
  overlay_ms=… resize_ms=… snapshot_ms=…
spore build profile: phase=session_start boot_ms=…
spore build profile: step=3 kind=RUN cache=miss exec_ms=… freeze_ms=…
  snapshot_ms=… dirty_chunks=… objects_written=… complete_stamp_ms=…
spore build profile: phase=finalize shutdown_ms=…
spore build profile: phase=publish ms=…
spore build profile: phase=total ms=…
```

Benchmark plan (M3, recorded in `docs/benchmarks.md`):

| Scenario | Baseline (buildx+import) | Target |
| --- | ---: | ---: |
| Fully cached wrapper rebuild | ~30s warm, ~25s BuildKit tar export | low single-digit wall, `spore build` ≤1s |
| One trailing RUN changed | 25-45s tar export + import on content change | command + one boot + dirty-only seal/index checkpoint |
| One context file changed | 25-45s tar export + import on content change | COPY apply + one boot + dirty-only seal/index checkpoint |
| Fully uncached (base cached) | BuildKit build + tar export + ~95s import | no tar export; one boot + work + seal/index checkpoints |
| Base image changed | base import + BuildKit build/export/import | import base once, then rerun changed steps directly |

Each row is measured with the profile phases above plus wall clock on the same
machine as the current buildkite-sporevm observations, and validated by booting
the result and running the Rails spec smoke. The baselines in this table predate
v7 capacity preparation and remain useful for the wrapper migration only. They
must not be cited as evidence for the current growth path; cold, prepared,
warm, incremental, large COPY/RUN, ENOSPC, HVF, and KVM capacity gates are
defined in `docs/plans/spore-build-rootfs-capacity.md`.

## Resolved Decisions

- Checkpoints, not layers: `spore build` produces rootfs CAS indexes; there is
  no layer composition mechanism and no requirement to export Docker layers
  back out (no two-way door). Intermediate states exist as step-key-addressed
  child `index_digest` outcomes.
- Execute both RUN and COPY inside one persistent build VM per build, with
  freeze/snapshot/thaw checkpoints between steps. Rejected: host-side
  `debugfs` writes for COPY (correctness surface too large), Docker-style COW
  layer composition (needs a new export/flatten API for less benefit than
  chunk-indexed rootfs snapshots), boot-snapshot-shutdown per step (kept only
  as the recorded de-risk fallback — same cache model, more boots).
- Writable `ChunkMappedDisk` overlay state for the session disk reuses the
  existing `spore_rootfs_rw` guest behavior without adding a device.
- Every executed step publishes an `index_digest`; child identities are
  recorded outcomes, with no determinism requirement on guest writes. Cache
  keys, not artifacts, carry determinism.
- Default `--network spore` for RUN (Docker parity; the target Dockerfile
  needs apt/curl). `--network none` for hermetic builds.
- `/bin/sh -c` for RUN, not `-lc` (Docker parity).
- The last step's `index_digest` is the final rootfs identity; the published
  local image identity additionally hashes that rootfs identity with canonical
  config JSON and still uses the existing local-ref machinery rather than
  inventing a parallel ref namespace.
- ARG over-invalidation (all declared args key all later exec steps, including
  unused ARGs) accepted for v1 simplicity; the target Dockerfile passes no build
  args.
- Grow-only sparse disk sizing; no shrink pass. The automatic target is
  `max(parent_logical_size, 16 GiB)`. Sixteen GiB is the automatic default and
  cap: smaller images normalize once, while images already at or above it keep
  their exact size. There is no hidden override, recursive doubling, additive
  growth, or public knob.
- Capacity normalization is the typed synthetic `PREPARE` operation in build
  cache v7, keyed by parent index, exact target, and exact kernel/initrd plus
  growth-contract producer identity. Dockerfile keys contain no capacity field,
  but bind the exact executor kernel/initrd identity; `--no-cache` still reuses
  PREPARE.
- The storage layer records the appended sparse tail as authoritative clean
  zero. Growth-only VMs transiently offer WRITE_ZEROES, and the managed initrd
  preflights journal-less source state before writable mount, revalidates it
  around `EXT4_IOC_RESIZE_FS`, and leaves ext4 correctness to the pinned kernel.
  The selected image has no shell or e2fsprogs dependency for preparation.
- The build executor calls the internal monitor path directly with writable
  rootfs and build-context state. Public `spore run --rootfs` remains
  read-only.
- Named `--build-context NAME=oci-layout://PATH` inputs are the builder's base
  image boundary. The wrapper can keep its generated application context while
  passing the separately prepared base OCI layout by name.
- An `ARG` declaration without a default records an absent value. Referencing
  that value during builder-owned substitution fails closed instead of
  silently substituting an empty string.

## Open Questions

- Capacity-at-import remains an optional optimization only if measurements show
  value. PREPARE is the product contract because it also covers existing local,
  committed, cached, and source-less images without multiplying formats or
  user intent.
- Any future automatic capacity above 16 GiB needs a compact index format or a
  lower proven dense-index ceiling; the current 64 MiB index limit is a hard
  format constraint, not a reason to add a user knob.

## Key Learnings From Pressure-Testing

- `--no-cache` makes the cache-key/artifact distinction operational, not just
  conceptual: the same deterministic input key can legitimately produce a new
  child snapshot. Only the derived step mapping is replaceable; CAS indexes and
  objects remain immutable and fail closed on conflicting bytes.
- The ext4 free-space problem is the biggest silent correctness trap: imported
  bases are sized to content, so the first apt-get in a RUN would ENOSPC.
  The implemented answer is reusable infrastructure normalization: compute the
  fixed absolute target, append clean-zero sparse coverage, let the pinned
  kernel resize ext4 directly, and publish PREPARE before arbitrary RUN. It is
  not a user-facing knob or an ENOSPC replay loop.
- Separating PREPARE from Dockerfile identity is what removes the cold-build
  cliff without pretending guest filesystem mutation is reproducible. One
  locally recorded child becomes the normal parent for unrelated Dockerfiles
  and forced executions; exact child index identity remains authoritative.
- Transient WRITE_ZEROES is a better use of the chunk-mapped architecture than
  teaching the host ext4 layout. Linux retains filesystem ownership, while
  storage-known zero operations avoid payload I/O and later zero scans.
- Guest-side COPY looked expensive at first (a VM boot to copy files) but
  removes the entire macOS host-filesystem fidelity problem (case
  sensitivity, ownership without root, xattrs); with the persistent session
  the boot is amortized across the whole build, so the objection dissolved.
- The first design (clone-boot-commit per step, content-hashed
  intermediates) paid boot+hash overhead per uncached step. The landed
  chunk-index primitives change the shape: the persistent session publishes a
  child `index_digest` after each frozen step, and "layers" collapse into
  cache records over rootfs CAS indexes.
- Valid step records root the indexes and objects they name. M4 GC/prune must
  retire unreachable build records before their CAS indexes, with complete
  stamps deleted before referenced indexes or chunks.
- The cached path must be fast *end to end*, not just inside `spore build`:
  the wrapper's `rm -rf` + 573M context copy would have silently kept the
  rebuild at ~30s. M3 explicitly owns the wrapper-side integration cost.
- Docker cache-semantics fidelity matters more than feature breadth: the test
  plan pins one golden test per invalidation rule so that "cached" never means
  "stale" — the failure mode that would destroy trust in the builder fastest.
