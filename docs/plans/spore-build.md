---
status: active
last_reviewed: 2026-07-09
spec_refs:
  - docs/rootfs.md
  - docs/filesystem.md
  - SECURITY.md
  - src/rootfs.zig
  - src/rootfs_cache.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/chunk_mapped_disk.zig
  - src/run.zig
related_plans:
  - docs/plans/native-ext4-writer.md
  - docs/plans/unified-chunk-disk.md
---

# Spore-Native Dockerfile Subset Builder (`spore build`)

> **Active** (revived 2026-07-09). This plan was deferred until the unified
> chunk-backed storage workstream landed. It has: inline CAS+index emission at
> import (#420), O(dirty) snapshots plus lazy rootfs materialization (#421),
> and O(1) rootfs completeness stamps for warm `--image` resolution (#423).
> The old 5m47s/347s framing is obsolete. Current `buildkite-sporevm`
> measurements put the warm wrapper flow around 30s, with roughly 25s in
> BuildKit's own tar export, warm `spore run --image` around 0.10s, and cold
> import around 95s when content changes. A separate autoresearch loop is
> attacking the remaining import hotspot in `src/rootfs/ext4_writer.zig`;
> this plan's job is to remove BuildKit tar export and avoid serializing a tar
> at all.
>
> The revival updates M2 onto the unified primitives instead of the original
> flat-file machinery: persistent-session checkpoints are `ChunkMappedDisk`
> overlay state; each per-instruction checkpoint is one O(dirty)
> `snapshotIndex()` into the rootfs CAS, producing a child `index_digest`; the
> guest `fsfreeze` protocol deferred by the unified plan is delivered here;
> and the executor still keys rootfs snapshots by the child `index_digest`.
> Published local image identity additionally includes the final image config:
> the local ref points at a digest over the final `index_digest` plus canonical
> config JSON, with a completeness stamp on the underlying rootfs storage so
> `spore run --image` takes the 0.10s path. The cache model, parser subset,
> COPY semantics, and fail-closed contract below remain valid.

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
  the changed steps and their O(dirty) snapshots, not for re-exporting or
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
- No new guest device model or monitor protocol. The build VM uses the
  existing device set and exec stream; the new guest contract is the
  `fsfreeze` checkpoint handshake driven over that stream.

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
- `--no-cache`: ignore step cache reads (still writes).
- `--mkfs PATH` / `--debugfs PATH`: forwarded to the base-import path, same as
  `spore rootfs import-oci`.

Build rootfs growth is automatic and not user-facing. On the first executor
miss in a session, the builder grows the writable sparse disk to
`max(2 * parent_logical_size, parent_logical_size + 8 GiB)`, rounded up to the
disk chunk size, then runs guest `resize2fs /dev/vda` once before Dockerfile
steps resume.

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
src/build/context.zig    .dockerignore-aware context walking + content
                         hashing for COPY
src/build/step_cache.zig step-key computation + on-disk records that map
                         deterministic parent+instruction inputs to child
                         index_digest outcomes
src/build/exec.zig       persistent build-VM session: boot the deepest
                         cached index writable through ChunkMappedDisk,
                         drive RUN/COPY through initrd agent requests,
                         checkpoint (freeze/snapshot/stamp/record/thaw)
                         after each build step
```

Build state machine:

```diagram
╭────────────╮   ╭──────────────╮   ╭──────────────────╮
│ parse +    │──▶│ resolve FROM │──▶│ walk instructions │
│ validate   │   │ → base index │   │ key_i = H(parent, │
│ Dockerfile │   │   blake3     │   │  instr, inputs)   │
╰────────────╯   ╰──────────────╯   ╰────────┬─────────╯
                                             │
                     all steps cached        │     first cache miss at step k
                          ╭──────────────────┴──────────────╮
                          ▼                                 ▼
                 ╭──────────────────╮   ╭──────────────────────────────╮
                 │ read final step  │   │ open index k-1 through       │
                 │ record, verify   │   │ ChunkMappedDisk + overlay    │
                 │ complete stamp   │   │ deterministic grow+resize2fs │
                 ╰────────┬─────────╯   │ boot guest once (rw)         │
                          │             │ for each remaining step:     │
                          │             │   agent request (RUN/COPY)   │
                          │             │   sync+freeze → snapshot →   │
                          │             │   stamp+record → thaw        │
                          │             │ shutdown                     │
                          │             ╰──────────────┬───────────────╯
                          ╰────────────────┬───────────╯
                                           ▼
                            ╭──────────────────────────────╮
                            │ publish image: register last │
                            │ index_digest + config under  │
                            │ the local ref                │
                            ╰──────────────────────────────╯
```

The orchestrator threads a `BuildState` through the instruction list:

```zig
const BuildState = struct {
    index_digest: [64]u8,       // current parent rootfs index identity
    step_key: [64]u8,           // current chain key
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

Metadata-only instructions (`ENV`, `ARG`, `WORKDIR`, `CMD`) advance `step_key`
and `BuildState` but never touch the rootfs and never boot anything; their
child `index_digest` is the parent `index_digest`. Only `RUN` and `COPY`
produce new rootfs indexes.

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

Each instruction produces a deterministic step key. The key is a cache lookup
address; the record at that address stores the child `index_digest` produced by
the prior successful execution.

```
step_key_0 = blake3("sporevm-build-v1" || builder_version || platform
                    || base_index_digest)
step_key_i = blake3("sporevm-build-step-v1" || platform
                    || parent_index_digest
                    || instruction_kind
                    || canonical_instruction
                    || input_digest
                    || env_digest
                    || workdir)
```

Per-instruction inputs:

- `FROM`: the resolved base `index_digest` (not the ref, not the manifest
  digest). Re-importing the same OCI layout yields the same rootfs index
  identity and the same chain; a changed base image invalidates everything.
- `RUN`: the exact command string, the effective environment (accumulated
  `ENV` plus every declared `ARG` as exported at that point, sorted
  canonical `K=V` list), the current `WORKDIR`, and the network mode.
  `input_digest` is empty.
- `COPY`: the substituted source patterns and dest, the current `WORKDIR`,
  and `input_digest` = the context content hash of the matched sources:
  after sorting by relative path and deduplicating repeated matches, each
  matched entry contributes length-prefixed fields to one BLAKE3 stream:
  `u64le(len(path)) || path || u64le(len(type)) || type ||
  u64le(len(mode)) || mode || u64le(len(payload)) || payload`. The payload is
  file content, symlink target text, or empty bytes for a directory.
  Ownership is not hashed (COPY forces 0:0). mtimes are not hashed
  (Docker parity).
- `ENV` / `ARG` / `WORKDIR` / `CMD`: the canonical instruction text after
  substitution. These advance the chain so a changed `ENV` invalidates every
  later `RUN`/`COPY` (Docker semantics), but a changed `CMD` — last
  instruction, metadata-only — keeps the same rootfs `index_digest` and costs
  only a local ref/config re-publish.

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
refs/local/<sha256>.json                            (existing) final ref
<image_cache_key>.json                              (existing) image metadata
```

Intermediates are input-addressed by their step key, but their artifacts are
normal rootfs CAS indexes. The step record is not restore authority; it is a
local memo from deterministic inputs to a child `index_digest`. A cache hit
requires the child index to parse, validate against the rootfs descriptor, and
have a completeness stamp proving all referenced nonzero chunks are present.
Missing or malformed indexes, missing complete stamps, or bad records are
treated as misses.

Step record, written atomically (temp + rename) only after `snapshotIndex()`
has published the index/chunks and the complete stamp exists:

```json
{
  "kind": "sporevm-build-step-v1",
  "builder_version": "…",
  "platform": {"os": "linux", "arch": "arm64"},
  "step_key": "…",
  "parent_index_digest": "…",
  "child_index_digest": "…",
  "instruction": "RUN apt-get update && …",
  "input_digest": "…",
  "env_digest": "…",
  "workdir": "/app",
  "created_unix": 1783732000
}
```

Final rootfs identities are **recorded outcomes, not recomputed promises**. Guest
writes (inode allocation, timestamps) are not deterministic, so the same step
key can map to different rootfs indexes on different machines or after a cache
wipe. That is the same model Docker uses: cache keys are deterministic, the
artifact identity is whatever the execution produced. Nothing downstream
assumes reproducibility of the ext4 bytes.

### Final image identity

The final image's rootfs identity is the last step's `index_digest`, but the
published local image identity is a digest over that `index_digest` plus the
canonical final image config JSON. That keeps two config-only variants with the
same rootfs from sharing a resolved image ref or metadata path. `spore build`
publishes the image digest through the same local-ref path as
`spore rootfs import-tar`, with image config metadata attached for `Env`,
`Cmd`, and `WorkingDir`; the exact digest construction is documented in
`docs/spore-format.md`.

```json
{
  "kind": "sporevm-built-image-v0",
  "builder_version": "…",
  "platform": {"os": "linux", "arch": "arm64"},
  "rootfs_storage": {
    "kind": "chunked-ext4-rootfs-v0",
    "index_digest": "…"
  },
  "config": {"Env": […], "Cmd": […], "WorkingDir": "…"}
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

Uncached steps execute in **one persistent build VM per build**, not one VM
per step. The guest boots once from the deepest cached `index_digest` opened
through `ChunkMappedDisk` with writable overlay state; every remaining RUN/COPY
runs inside that session; checkpoints are taken between steps by freezing the
filesystem, draining virtio-blk, and publishing one O(dirty) rootfs CAS index.

Session lifecycle:

1. Open the deepest cached `index_digest` (or the base `FROM` index for a
   fully cold build) as the `ChunkMappedDisk` parent and attach build-owned
   writable overlay state. The parent index and complete stamp are verified
   before boot; missing chunks fail closed instead of reaching the guest.
2. Grow the writable chunk-mapped rootfs to
   `max(2 * parent_logical_size, parent_logical_size + 8 GiB)` rounded to the
   disk chunk size, then run guest `resize2fs /dev/vda` once before the first
   Dockerfile step. No shrink after; later snapshots and the final published
   image inherit the larger logical size deliberately, because run-time
   workloads also benefit from scratch space and chunk-mapped disks are sparse.
3. Boot via the existing run stack with a new internal rootfs mode: open the
   chunk-mapped rootfs read-write and pass `spore_rootfs_rw=1`, without
   changing public `spore run` semantics. This is a builder-only option behind
   the hypervisor-neutral disk interface.
4. The host drives the existing initrd agent over bounded `spore_stream_v1`
   requests:
   - `RUN`: host sends the script plus the step's effective env and workdir;
     driver runs `/bin/sh -c` as root (Docker parity: `-c`, not the `-lc`
     that `spore run`'s shell mode uses), streams output through, reports the
     exit code. Network per `--network` for the whole session.
   - `COPY`: host sends a `spore-copy-v1` JSON request with destination and
     entry count, then length-prefixed dir/file/symlink entries over SPIO stdin;
     the agent validates bounds and guest paths before applying them under
     `/mnt/rootfs` (see COPY Semantics).
   - `CHECKPOINT`: agent handles `fsfreeze-v1` after the step exits;
     the VMM drains/flushes pending virtio-blk writes, the host calls
     `ChunkMappedDisk.snapshotIndex()` into the rootfs CAS, writes/repairs the
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
5. A non-zero step exit fails the build with the exit code and the
   instruction; the session is torn down, live overlay state is deleted, and
   no record is written for the failed step. Checkpoints of earlier successful
   steps remain valid — the retry resumes from the last recorded
   `index_digest`.
6. After the last step's snapshot and shutdown: publish the last
   `index_digest` under the requested local image ref. There is no final
   full-image hash or flat install pass.

Overhead on a cache miss, on top of the commands themselves: one boot
(~1–2s per build), deterministic one-time grow+`resize2fs`,
sync+freeze+O(dirty) snapshot per changed step, and local-ref publication.
There is no tar export, no full-image hash, and no flat materialization
required before the image is runnable. Fixed overhead is one boot plus the
dirty snapshot work, so uncached builds compete with BuildKit by avoiding
BuildKit's export and Spore's import boundary entirely.

De-risk fallback, recorded not planned: if persistent in-guest orchestration
regresses, the degenerate mode is one boot-snapshot-shutdown cycle per step
(same cache records and `index_digest` outcomes, N boots). It costs one boot
per changed step instead of per build; the cache model is identical in both
modes.

The guest sees exactly what `spore run --image X --save` sees today
(`spore_rootfs=1 spore_rootfs_rw=1`). The initrd agent now provides the build
control verbs (`fsfreeze-v1`, `fsthaw-v1`, `spore-copy-v1`); the target base
must provide `/bin/sh` for RUN and `resize2fs` for executor misses. A missing
guest requirement fails closed through the step's captured output.

## COPY Semantics

`COPY` goes **through the guest**, inside the same persistent build-VM
session as `RUN`, rather than host-side ext4 surgery:

1. On the host, resolve sources against the context with the same walker used
   by `hashCopySources` (no `..` escapes, no absolute sources, `.dockerignore`
   already applied). The resolved, sorted, deduped file set is both the cache
   input digest and the payload source, so keys cannot drift from bytes.
2. Map Docker destinations on the host: directory sources copy contents,
   multiple sources require a `/`-terminated destination, relative destinations
   resolve against `WORKDIR`, and guest paths containing `..` fail closed.
3. Send a `spore-copy-v1` request plus a length-prefixed entry stream over the
   existing SPIO stdin frames. Each entry has kind (dir/file/symlink), mode,
   absolute guest path, and content bytes for files or symlink targets. The
   agent resolves apply paths relative to an fd for `/mnt/rootfs` with
   `openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)`, falling back only to a
   fail-closed component walk that keeps symlink targets rooted in the rootfs.
   It applies entries with root ownership, parent creation, directory merge,
   file overwrite, and symlink preservation.
4. Checkpoint exactly as RUN does (freeze, O(dirty) snapshot, complete stamp,
   step record, thaw).

Corollary: COPY does not require `tar` in the base image and does not add a tar
parser to the initrd agent. Hardlinks, xattrs, `--chown`, `--chmod`, `--from`,
`--link`, `ADD`, and multi-stage builds remain unsupported and fail closed.

Why the guest and not `debugfs` writes or host staging: a real Linux kernel
applies ownership, modes, symlinks, and directory merge behavior natively and
correctly, with no root requirement on the host and no macOS case-sensitivity
or metadata hazards. `debugfs -w` scripting for arbitrary tree merges
(overwrite-vs-merge, unlink-before-write, hardlinks) is a large correctness
surface for no architectural payoff. With the persistent session the guest
boot is already amortized across the whole build, so COPY's marginal cost is
the entry stream plus one freeze/snapshot checkpoint. Host-side COPY (writing
directly into the rootfs without the guest) stays a documented follow-up for
the case where a COPY is the *only* uncached step; it needs a separate design
and is not v1.

Docker semantic contract, tested explicitly:

- `COPY dir/ /dest/` copies the *contents* of `dir` into `/dest`.
- Multiple sources require a `/`-terminated destination.
- Relative destinations resolve against the current `WORKDIR`.
- Copied entries are owned `0:0`; file modes come from the context.
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
  (M1 for the parser; M2 COPY keeps host payload generation on the same
  resolver path and bounds the guest entry parser).
- `RUN` executes arbitrary user commands — inside the SporeVM guest, which is
  the existing isolation boundary. The builder adds no new device model, no
  new virtqueue parsing, and no monitor changes outside the existing
  hypervisor-neutral disk interface. The runtime change is opening a
  build-owned `ChunkMappedDisk` read-write instead of opening an immutable
  run image read-only.
- Step records under `build/steps/` are trusted local build metadata — same
  trust level as the cache directory that holds them — and never leave
  `build/`. The rootfs artifacts they name are normal rootfs CAS
  indexes/objects. Records that reference missing or malformed indexes, or
  indexes without a complete stamp, are treated as misses and are never
  repaired in place.
- COPY source resolution must not escape the context directory (reject `..`
  traversal and absolute sources after substitution).
- Built-image metadata must not be mistakable for portable OCI provenance:
  `kind: sporevm-built-image-v0`, `layers: []`, and explicit
  `rootfs_storage` pointing at the final `index_digest`. This is the local
  rootfs metadata field name; portable spore manifests continue to use
  `rootfs.storage`.
- Machine state and spore format are untouched. No manifest format changes.

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
each O(dirty) snapshot.

Definition of done:
- Dockerfile parser unit tests cover the supported subset and exact
  fail-closed errors for unsupported features.
- Parser and `.dockerignore`/context-ingestion fuzz targets are in-tree in the
  same change as the new parsers.
- A fully cached fixture build resolves the final `index_digest`, verifies the
  complete stamp, updates the local ref, and exits in <1s without booting a VM.
- A metadata-only Dockerfile (`FROM`/`ENV`/`ARG`/`WORKDIR`/`CMD`) publishes a
  runnable image by reusing the base `index_digest`; a second invocation is a
  full cache hit in <1s.
- `spore run --image local/x:dev -- /bin/true` boots the published result.
- `mise run build` and `zig build test --summary all` pass.

Ceiling proven: cached build resolution and ref publication <1s; base import
cost paid once.

### M2 — RUN/COPY via the persistent build-VM session

The session executor: open the deepest cached index through `ChunkMappedDisk`
with build-owned overlay state, rw rootfs boot behind the hypervisor-neutral
disk interface, bounded agent requests over `spore_stream_v1`, `/bin/sh -c`
RUN steps with env/workdir/network, `spore-copy-v1` COPY entry streams,
freeze/snapshot/stamp/record/thaw checkpointing (including the virtio-blk drain),
complete-stamp publication, streamed step output, and non-zero-exit cleanup.
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
- deterministic grow/resize2fs is exercised by the gated build smoke before
  Dockerfile steps execute.

Ceiling proven: uncached RUN/COPY build = one boot + deterministic resize + step
time + O(dirty) snapshots; cached build ≈ 0.

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
The build VM memory is currently a provisional 2 GiB default; promote it to a
`spore build` option when real workloads such as large `bundle install`-style
RUN steps need more headroom.

Implementation note (2026-07-09, COPY slice): the executor step list is now a
tagged RUN/COPY sequence, so the first uncached COPY enters the same persistent
VM path as RUN. COPY write-side keys use the same `StepInput` fields the M1
resolver reads: parent index, `"COPY"`, raw instruction, build-context input
digest, environment digest, and workdir. Host payload generation reuses the
same build-context resolver as hashing, maps Docker destinations before boot,
and streams a bounded custom `spore-copy-v1` entry protocol rather than tar.
The guest agent validates entry count, kind, mode, path length, content length,
and `..` components, then confines all apply-path resolution to `/mnt/rootfs`
while preserving Docker-style rootfs-internal symlink traversal. COPY
checkpoints use the same freeze → snapshot → complete stamp → step record →
thaw ordering as RUN. Session start uses the deterministic sparse grow policy
above and includes the resolved grow target in the first executor-written step
key; the hidden `--disk-headroom` debug override bypasses the policy and uses
the same key field. A manual Docker-vs-Spore metadata oracle lives at
`scripts/spore-build-copy-oracle.sh`.

Remaining M2 completion work: prove the full `buildkite-sporevm` wrapper path
against the real Buildkite base end to end and record the measured acceptance
output here.

Definition of done:
- The full `buildkite-sporevm` Dockerfile (`FROM base`, apt RUN, five COPYs,
  chmod RUN, CMD) builds end to end with no BuildKit involvement.
- File-tree diff of the built rootfs against the docker-buildx-built rootfs
  for the same inputs shows only expected divergence (mtimes, `/etc/resolv.conf`
  placeholder, ext4 identity) — paths, modes, sizes, symlink targets, uid/gid
  match.
- Touching one context file invalidates exactly the COPY that matched it and
  later steps.
- COPY semantics test matrix passes (dir-contents, multi-source, relative
  dest, overwrite/merge, symlink, empty dir, mode preservation, exec bit).

Ceiling proven: cached full build (parse + context hash + lookups + ref
refresh) ≤2s cold-stat, target <1s; uncached COPY ≈ entry stream + guest apply
plus one freeze/O(dirty) snapshot, with boot amortized per build.

### M4 — Wrapper switch and benchmark

Patch `bin/buildkite-spore`: replace buildx/import-tar with `spore build`,
make `prepare_context` incremental/clonefile-based. Add build profiling
phases (see Verification) and record before/after in `docs/benchmarks.md`.

Definition of done:
- `buildkite-spore build` (cached) completes in single-digit seconds wall
  clock, from the current ~30s warm baseline, with `spore build` itself <1s.
- `buildkite-spore start` boots the built image, `setup-spore` reaches
  `/tmp/sporevm-buildkite/ready`, and `buildkite-spore rspec <known-good
  spec>` passes — the rootfs is proven equivalent for the real workload.
- Uncached full build wall clock recorded; target ≤ current uncached path.
- Benchmark script lives in `scripts/` and runs identically by hand and in CI
  where hardware allows.

### M5 — Ergonomics and hardening (follow-ups, ordered by need)

- Per-file context hash cache keyed by (path, size, mtime, inode) so warm
  context hashing is stat-only.
- `spore build .` with `-f` defaults, once the narrow wrapper path is proven.
- `spore build prune` / step-cache GC for build records and CAS indexes that
  are no longer reachable from local refs or live build-cache records.
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
- Step cache: records survive process restart; missing artifact ⇒ miss;
  corrupted record ⇒ miss; missing complete stamp ⇒ miss; atomic write (no
  partial records after simulated crash between snapshot publication and
  record write).
- Executor: exit-code propagation, env/workdir application, network
  on/off, deterministic disk growth, failure cleanup.
- COPY matrix listed above, plus context-escape rejection tests.
- End-to-end: small fixture base (tiny OCI layout already used by import
  tests) through FROM+RUN+COPY+CMD, then `spore run` smoke; the real
  `buildkite-sporevm` path as the M4 hardware smoke.
- Equivalence: scripted file-tree diff (path, type, mode, uid/gid, size,
  symlink target) between spore-built and buildx-built rootfs.

Instrumentation (extends the existing `SPOREVM_ROOTFS_BUILD_PROFILE`
convention, same output shape):

```
spore build profile: phase=parse ms=…
spore build profile: phase=base_resolve ms=…
spore build profile: phase=context_hash ms=…
spore build profile: phase=session_start overlay_ms=… resize_ms=… boot_ms=…
spore build profile: step=3 kind=RUN cache=miss exec_ms=… freeze_ms=…
  snapshot_ms=… dirty_chunks=… objects_written=… complete_stamp_ms=…
spore build profile: phase=finalize shutdown_ms=…
spore build profile: phase=publish ms=…
spore build profile: phase=total ms=…
```

Benchmark plan (M4, recorded in `docs/benchmarks.md`):

| Scenario | Baseline (buildx+import) | Target |
| --- | ---: | ---: |
| Fully cached wrapper rebuild | ~30s warm, ~25s BuildKit tar export | low single-digit wall, `spore build` ≤1s |
| One trailing RUN changed | 25-45s tar export + import on content change | command + one boot + O(dirty) snapshot |
| One context file changed | 25-45s tar export + import on content change | COPY apply + one boot + O(dirty) snapshot |
| Fully uncached (base cached) | BuildKit build + tar export + ~95s import | no tar export; one boot + work + O(dirty) snapshots |
| Base image changed | base import + BuildKit build/export/import | import base once, then rerun changed steps directly |

Each row is measured with the profile phases above plus wall clock on the same
machine as the current buildkite-sporevm observations, and validated by booting
the result and running the Rails spec smoke.

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
- Grow-only sparse disk sizing in v1; no shrink pass. The automatic target is
  `max(2 * parent_logical_size, parent_logical_size + 8 GiB)` rounded to chunk
  size, with a hidden debug override only for diagnosing ENOSPC workloads.

## Open Questions

- Unset `ARG` without default: hard error (proposed, fail-closed bias) versus
  Docker's empty-string-plus-warning. Default: hard error until a consumer
  needs otherwise.
- Where the internal rw-rootfs run mode lives: a private field on
  `run_mod.Options` versus a narrower executor entry point that bypasses
  `api.runManaged`. Decide in M2 against the actual code; the constraint is
  that public `spore run` semantics (plain `--rootfs` stays read-only) do not
  change.
- Whether M4 keeps the wrapper's generated-context design or teaches
  `spore build` multiple contexts. Default: keep the generated context; it is
  cheap once copies are clonefile-based.
- Teach import-tar/native ext4 emission to create generously sized sparse
  images at import time, so build-start resize becomes a fallback for old or
  unusually small images rather than routine work.
- Reuse the same sizing policy for `spore run` writable rootfs paths when that
  path grows rootfs disks by default; do not change public run semantics in M2.

## Key Learnings From Pressure-Testing

- The ext4 free-space problem is the biggest silent correctness trap: imported
  bases are sized to content, so the first apt-get in a RUN would ENOSPC.
  The plan makes automatic sparse growth a first-class, tested step (open
  index → compute deterministic target → grow → resize2fs → boot) rather than
  a user-facing knob or an incident discovered in M4.
- Guest-side COPY looked expensive at first (a VM boot to copy files) but
  removes the entire macOS host-filesystem fidelity problem (case
  sensitivity, ownership without root, xattrs); with the persistent session
  the boot is amortized across the whole build, so the objection dissolved.
- The first design (clone-boot-commit per step, content-hashed
  intermediates) paid boot+hash overhead per uncached step. The landed
  chunk-index primitives change the shape: the persistent session publishes a
  child `index_digest` after each frozen step, and "layers" collapse into
  cache records over rootfs CAS indexes.
- Step records can outlive the indexes or objects they name. GC/prune must
  remove unreachable build records and CAS indexes carefully, with complete
  stamps deleted before referenced indexes or chunks.
- The cached path must be fast *end to end*, not just inside `spore build`:
  the wrapper's `rm -rf` + 573M context copy would have silently kept the
  rebuild at ~30s. M4 explicitly owns the wrapper-side incremental context.
- Docker cache-semantics fidelity matters more than feature breadth: the test
  plan pins one golden test per invalidation rule so that "cached" never means
  "stale" — the failure mode that would destroy trust in the builder fastest.
