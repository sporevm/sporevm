---
status: deferred
last_reviewed: 2026-07-08
spec_refs:
  - docs/rootfs.md
  - docs/filesystem.md
  - SECURITY.md
  - src/rootfs.zig
  - src/rootfs_cache.zig
  - src/run.zig
related_plans:
  - docs/plans/native-ext4-writer.md
  - docs/plans/unified-chunk-disk.md
---

# Spore-Native Dockerfile Subset Builder (`spore build`)

> **Deferred** (re-sequenced 2026-07-08). This plan was drafted when the
> buildx→import-tar boundary cost minutes even fully cached. Since then the
> native ext4 writer landed (import conversion ~24s → ~7.8s on the reference
> benchmark, `docs/plans/native-ext4-writer.md`), an imported-rootfs cache
> fast path made repeat imports resolve without re-conversion, and
> `docs/plans/unified-chunk-disk.md` became the active storage workstream.
> That plan's U4 (inline chunk+index emission at import, no separate
> full-image hash) and U7 (partial materialization — cold `--image` start
> bounded by boot working set, not image size) attack the same boundary this
> builder was designed to bypass.
>
> Revisit only if the buildx + `spore rootfs import-tar` path still hurts
> after U4/U7 land. If revived, rebuild M2's executor on the unified
> primitives instead of this plan's bespoke flat-file machinery: the
> persistent-session checkpoints become `ChunkMappedDisk` overlay state, the
> online guest `fsfreeze` protocol (which the unified plan's v1 explicitly
> defers to here) is this plan's to deliver, and finalize becomes one
> `snapshot()` per the unified plan's durable-index invariant — no terminal
> full-image hash. The cache model, parser subset, COPY semantics, and
> fail-closed contract below remain valid as written.

## Summary

Add a `spore build` command that executes a narrow Dockerfile subset directly
against Spore rootfs artifacts, with a deterministic per-instruction cache, so
that a fully cached rebuild resolves the final rootfs identity and updates the
local image ref without booting anything, exporting anything, or touching
BuildKit.

This replaces the earlier direction of optimizing the BuildKit-to-Spore
conversion boundary. That work got flat imports from ~262s to ~179s, but the
boundary itself (BuildKit snapshot → tar export → Spore staging → ext4) has a
floor of minutes. The observed cached `buildkite-sporevm` rebuild is 5m47s
wall clock with only 47.3s inside Docker/BuildKit. The rest is export,
transfer, and re-import of bytes that already exist on both sides. This plan
removes the boundary entirely for the common path instead of shaving it.

The builder does not reimplement BuildKit. It supports exactly the instructions
the `buildkite-sporevm` wrapper's Dockerfile needs — `FROM` (including a named
`--build-context` OCI layout base), shell-form `RUN`, flag-less `COPY`, `ENV`,
`ARG`, `WORKDIR`, `CMD` — and fails closed with an actionable error on
everything else.

## Problem

The current `bin/buildkite-spore build` flow is:

1. `docker buildx build --build-context base=oci-layout://… --output
   type=tar,dest=…` (47.3s reported, all Dockerfile steps cached; 44.6s of that
   is "exporting to client tarball").
2. `spore rootfs import-tar …` (~179s in the old flat-import measurement: 64s
   staging extraction, 47s mkfs, 39s debugfs, 10s blake3).
3. `spore run --image local/buildkite-spore:dev …`.

Even when every Dockerfile step is cached, the pipeline serializes a ~4.1G tar
out of BuildKit and rebuilds an ~8G ext4 from scratch. The rootfs it produces
is byte-identical to the one built last time. Roughly 300s of the 347s wall
clock is spent proving that.

No amount of import optimization fixes this: the remaining phases
(`layer_extract_staging`, `mkfs_ext4`, `debugfs_finalize`, and final rootfs
CAS indexing) are the irreducible cost of converting a tar into an ext4 and
publishing it as a Spore rootfs. The only way to make the cached path fast is
to not produce the tar at all.

## Goals

- A fully cached `spore build` of the `buildkite-sporevm` Dockerfile completes
  in under one second: hash inputs, resolve the final rootfs identity from the
  step cache, refresh the local ref, exit.
- A partially cached rebuild (one changed trailing instruction) pays only for
  the changed steps, not for re-exporting or re-importing the base.
- The built image is a first-class local Spore image: `spore run --image
  local/buildkite-spore:dev -- /bin/true` resolves and boots it through the
  existing digest cache and local ref machinery with no new run-path formats.
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
- No content hashing or indexing of intermediate checkpoints, and no
  dirty-extent / incremental indexing in v1. Only the final rootfs is indexed
  once per uncached build; dirty-extent tracking and incremental CAS maintenance
  are a scheduled follow-up (M5).
- No cross-machine or shared build cache. The step cache is local, same trust
  model as the existing rootfs materialization cache.
- No `.dockerignore` in the first milestones. The wrapper's generated context
  contains only explicitly copied files. `.dockerignore` lands with the
  general-ergonomics milestone.
- No guest-agent changes beyond what the existing exec protocol already
  provides.

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
- `--disk-headroom SIZE`: free ext4 space guaranteed at build-session start
  (default `2gb`, see RUN execution below).
- `--no-cache`: ignore step cache reads (still writes).
- `--mkfs PATH` / `--debugfs PATH`: forwarded to the base-import path, same as
  `spore rootfs import-oci`.

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
| `CMD ["…"]` / `CMD <shell>` | final image config only. |
| comments, line continuations, `${VAR}`/`$VAR` substitution in instruction arguments | standard Dockerfile behavior. |

Variable substitution applies to `ENV`, `ARG` defaults, `WORKDIR`, `COPY`
arguments, and `CMD`, using the declared `ARG`/`ENV` state, as Docker does.
`RUN` strings are not pre-expanded; the guest shell expands them, with
`ARG`/`ENV` values exported into the step environment.

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
src/build/context.zig    context walking + content hashing for COPY
src/build/step_cache.zig step-key computation + on-disk step records
src/build/exec.zig       persistent build-VM session: boot the deepest
                         cached checkpoint writable, drive RUN/COPY steps
                         through an in-guest step driver, checkpoint
                         (freeze/clone/thaw) after each exec step, commit
                         the final rootfs
```

Build state machine:

```diagram
╭────────────╮   ╭──────────────╮   ╭──────────────────╮
│ parse +    │──▶│ resolve FROM │──▶│ walk instructions │
│ validate   │   │ → base rootfs│   │ key_i = H(key_i-1,│
│ Dockerfile │   │   blake3     │   │  instr, inputs)   │
╰────────────╯   ╰──────────────╯   ╰────────┬─────────╯
                                             │
                     all steps cached        │     first cache miss at step k
                          ╭──────────────────┴──────────────╮
                          ▼                                 ▼
                 ╭──────────────────╮   ╭──────────────────────────────╮
                 │ read last step   │   │ clone checkpoint k-1         │
                 │ record, reuse    │   │ (reflink) → live build file  │
                 │ memoized digest  │   │ grow + resize2fs (once)      │
                 ╰────────┬─────────╯   │ boot guest once (rw)         │
                          │             │ for each remaining step:     │
                          │             │   exec via step driver       │
                          │             │   sync+freeze → clone →      │
                          │             │   thaw = checkpoint(key_i)   │
                          │             │ shutdown, blake3 final,      │
                          │             │ install by-digest            │
                          │             ╰──────────────┬───────────────╯
                          ╰────────────────┬───────────╯
                                           ▼
                            ╭──────────────────────────────╮
                            │ publish image: synthesize    │
                            │ config, image-keyed .ext4 +  │
                            │ .json, refresh local ref     │
                            ╰──────────────────────────────╯
```

The orchestrator threads a `BuildState` through the instruction list:

```zig
const BuildState = struct {
    rootfs_identity: [64]u8,    // current parent rootfs index identity
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
extra keying: they are a pure function of the base rootfs identity that already
roots the chain.

Metadata-only instructions (`ENV`, `ARG`, `WORKDIR`, `CMD`) advance `step_key`
and `BuildState` but never touch the rootfs and never boot anything. Only
`RUN` and `COPY` produce new rootfs artifacts.

Reused existing machinery, unchanged:

- `importOciLayout` (`src/rootfs.zig:779`) resolves `--build-context`
  oci-layout bases, cached by manifest digest — a base that was imported last
  build is a cache hit.
- `rootfs_cache` (`src/rootfs_cache.zig`) stores every intermediate and final
  rootfs materialization at `<cache_root>/by-digest/blake3/<hex>.ext4`,
  verify-at-install, trust-at-open, including the hardlink fast path.
- Local ref records (`refs/local/<sha256>.json`, `writeLocalRefCache`) and the
  image-keyed `<cache_key>.ext4`/`.json` pair make the result visible to
  `spore run --image` with no run-path changes.
- The run/exec stack (`run_mod.execute`, vsock exec protocol, exit codes,
  `--net` gateway) executes guest steps.

## Cache Model

### Checkpoints, not layers

`spore build` has no layer concept. The artifact of every step — and of the
final image — is one flat ext4 rootfs. OCI layers exist only at the `FROM`
edge, parsed once by the existing import path and never re-emitted. There is
no overlay, no whiteout resolution at build or run time, and no flatten/export
pass; the run path consumes the result unchanged.

The three jobs Docker layers perform are covered separately:

- **Caching**: key-addressed checkpoints. Each exec step's frozen ext4 is
  reflink-cloned and recorded under its deterministic step key. A cache hit
  resolves a key, not a layer stack.
- **Storage sharing**: filesystem copy-on-write. Reflink checkpoints share
  unmodified blocks physically, so N checkpoints of an 8G image cost 8G plus
  the blocks each step wrote (APFS/reflink filesystems; plain-copy fallback
  documented under GC in M5).
- **Distribution/dedupe**: the existing rootfs CAS (fixed 64KiB chunks,
  `spore-disk-index-v1`), derived for the final published image — layers are
  never needed as the dedupe unit.

Accepted one-way door: built images cannot be exported back to Docker (there
are no layers to emit). Checkpoint granularity is whole-image logical / dirty
blocks physical; making it dirty-sized in *both* storage and hashing is the
dirty-extent follow-up in M5 below, which converges with the chunked CAS.

### Step keys

Each instruction produces a deterministic step key:

```
step_key_0   = blake3("sporevm-build-v0" || builder_version || platform
                      || base_rootfs_identity)
step_key_i   = blake3(step_key_{i-1} || instruction_kind
                      || canonical_instruction || input_digest)
```

Per-instruction inputs:

- `FROM`: the resolved base **rootfs identity** (not the ref, not the manifest
  digest). Re-importing the same OCI layout yields the same rootfs index
  identity and the same chain; a changed base image invalidates everything.
- `RUN`: the exact command string, the effective environment (accumulated
  `ENV` plus every declared `ARG` as exported at that point, sorted
  canonical `K=V` list), the current `WORKDIR`, and the network mode.
  `input_digest` is empty.
- `COPY`: the substituted source patterns and dest, the current `WORKDIR`,
  and `input_digest` = the context content hash of the matched sources:
  for each matched file in sorted relative-path order,
  `blake3(rel_path || type || mode || symlink_target || content)`.
  Ownership is not hashed (COPY forces 0:0). mtimes are not hashed
  (Docker parity).
- `ENV` / `ARG` / `WORKDIR` / `CMD`: the canonical instruction text after
  substitution. These advance the chain so a changed `ENV` invalidates every
  later `RUN`/`COPY` (Docker semantics), but a changed `CMD` — last
  instruction, metadata-only — costs nothing but a config re-publish.

`ARG` follows this simplification: a declared ARG's value enters the effective
environment of every subsequent `RUN`/`COPY`, so changing any declared
`--build-arg` invalidates subsequent execution steps even if unreferenced.
This over-invalidates relative to Docker (which tracks reference), and is
recorded as an accepted tradeoff below.

### On-disk layout

All under the existing rootfs cache root (`local_paths.rootfsCacheRootPath`):

```
by-digest/blake3/<hex>.ext4        (existing) final rootfs only
build/steps/<step_key>.ext4        checkpoint: key-addressed intermediate rootfs
build/steps/<step_key>.json        step record
refs/local/<sha256>.json           (existing) final ref
<image_cache_key>.ext4 / .json     (existing) final image-keyed artifact + metadata
```

Intermediates are **input-addressed, never content-hashed**: a checkpoint is
stored and looked up by its step key alone. Only the build's final rootfs gets
a BLAKE3 (one full-image hash per uncached build) and a verify-at-install
entry in the by-digest cache, because that digest is what the run path and
`rootfs.storage` upgrade consume. Checkpoints are local, trusted build state —
same trust level as the cache directory that holds them — and never leave
`build/`; anything portable goes through the verified by-digest install.

Step record, written atomically (temp + rename) only after the checkpoint
clone succeeds:

```json
{
  "kind": "sporevm-build-step-v0",
  "builder_version": "…",
  "platform": {"os": "linux", "arch": "arm64"},
  "step_key": "…",
  "parent_step_key": "…",
  "instruction": "RUN apt-get update && …",
  "checkpoint_size": 7969177600,
  "rootfs_identity": null,
  "created_unix": 1783732000
}
```

`rootfs_identity` is a memo, not a promise: it is filled in the first time that
checkpoint is published as a final image (indexed once, then reused), so a
fully cached rebuild publishes refs without rescanning the flat checkpoint. A
checkpoint that was intermediate in one build and final in a shorter Dockerfile
pays the index pass once at first publication.

A cache hit requires the record to parse, `kind`/`builder_version`/`platform`
to match, and `build/steps/<step_key>.ext4` to exist as a regular readable
file. A record pointing at a pruned checkpoint is treated as a miss and
rewritten.

Final rootfs identities are **recorded outcomes, not recomputed promises**. Guest
writes (inode allocation, timestamps) are not deterministic, so the same step
key can map to different rootfs indexes on different machines or after a cache
wipe. That is the same model Docker uses: cache keys are deterministic, the
artifact identity is whatever the execution produced. Nothing downstream
assumes reproducibility of the ext4 bytes.

### Final image identity

Built images have no OCI manifest, so `spore build` synthesizes one canonical
config document:

```json
{
  "kind": "sporevm-built-image-v0",
  "builder_version": "…",
  "platform": {"os": "linux", "arch": "arm64"},
  "rootfs_identity": "blake3:…",
  "config": {"Env": […], "Cmd": […], "WorkingDir": "…"}
}
```

Its SHA256 becomes the image's "manifest digest", giving `local/name@sha256:…`
through the existing `localResolvedImageRef` shape. Publication then follows
the import path exactly:

1. install or hardlink the flat materialization under the rootfs index identity
   and to `<image_cache_key>.ext4`
   (`rootfsCacheKeyAlloc` over builder version, platform, synthesized digest,
   resolved ref);
2. write an `RootFSMetadata`-compatible `.json` sidecar: `config` carries
   `Env`/`Cmd`/`WorkingDir` so `readCachedImageRunConfig` picks them up at run
   time; `layers` is empty; `config_digest` is the synthesized digest;
   `deterministic` is `false` with empty `ext4_uuid`/`ext4_hash_seed`
   (guest-mutated images are not mkfs-deterministic — the metadata reader must
   tolerate this, a small compatible change);
3. `writeLocalRefCache` for the mutable tag.

Result: `spore run --image local/buildkite-spore:dev` works today's way, and
`--save` records portable chunked storage immediately because the cache
metadata already carries the rootfs storage index.

## RUN Execution And Snapshot

Uncached steps execute in **one persistent build VM per build**, not one VM
per step. The guest boots once from a writable clone of the deepest cached
checkpoint; every remaining RUN/COPY runs inside that session; checkpoints are
taken between steps by freezing the filesystem and reflink-cloning the backing
file on the host.

Session lifecycle:

1. Clone the deepest cached checkpoint's ext4 (or the base by-digest ext4 for
   a fully cold build) into a live build temp file. On APFS this is
   `clonefile(2)` (instant, shares blocks); on Linux `FICLONE` where the
   filesystem supports it, else a full copy.
2. Guarantee headroom **once per build**: if the ext4 has less than
   `--disk-headroom` free, extend the sparse file and run host-side
   `resize2fs` (already implied by the e2fsprogs dependency). No shrink after;
   checkpoints inherit the size, and sparse files keep physical cost bounded.
3. Boot via the existing run stack with a new internal rootfs mode: open the
   live file read-write and pass `spore_rootfs_rw=1`, without the
   manifest-bound `.rootfs` + COW machinery that `--save` uses today. This is
   a small extension to `runtime_disk.zig` (`openRootfsDisk` currently opens
   `O_RDONLY` unconditionally) plus a run option that only the builder sets.
4. The single exec'd guest command is a **step driver**: a self-contained
   POSIX-sh program passed as the exec command line (no guest install, no
   injected binary in v1). It speaks a length-framed protocol over the
   existing vsock exec stdin/stdout stream (`spore_stream_v1` — the same
   file-backed stdin extension COPY needs):
   - `RUN`: host sends the script plus the step's effective env and workdir;
     driver runs `/bin/sh -c` as root (Docker parity: `-c`, not the `-lc`
     that `spore run`'s shell mode uses), streams output through, reports the
     exit code. Network per `--network` for the whole session.
   - `COPY`: host sends a byte-counted tar payload; driver extracts it (see
     COPY Semantics).
   - `CHECKPOINT`: driver runs `sync` then `fsfreeze -f /` and acknowledges;
     the host reflink-clones the live file to `build/steps/<step_key>.ext4`
     and writes the step record; driver thaws on the host's signal. The
     driver itself only waits on stdin during the freeze, so it never blocks
     on the frozen root. Because all step processes have already exited and
     the filesystem is frozen at clone time, checkpoints are clean images,
     not crash-consistent guesses — this matters because the rootfs ext4
     profile has no journal. The VMM must drain/flush pending virtio-blk
     writes to the backing file before cloning; we own that write path
     (`src/virtio/blk.zig`).
   - `DONE`: driver exits; guest shuts down cleanly.
5. A non-zero step exit fails the build with the exit code and the
   instruction; the session is torn down, the live file is deleted, and no
   record is written for the failed step. Checkpoints of earlier successful
   steps remain valid — the retry resumes from the last checkpoint.
6. After the last step's checkpoint and shutdown: BLAKE3 the final checkpoint
   (the only full-image hash in the build), install into the digest cache via
   the existing hardlink fast path, memoize the digest in the step record,
   publish.

Overhead on a cache miss, on top of the commands themselves: one boot
(~1–2s per build), one resize2fs (seconds, cold builds only in practice),
sync+freeze+clone per step (~0.1s), one final BLAKE3 of ~8–10G (~10s), install
(~0). Total fixed cost is ~15s **per build**, not per step — an uncached build
is one boot + the actual work + one hash, which is BuildKit-competitive.

De-risk fallback, recorded not planned: if the step driver proves gnarly in
M2, the degenerate mode is one clone-boot-commit cycle per step (same
checkpoint and commit machinery, N boots + per-step hashing). It costs ~15s
per step instead of per build and requires no driver protocol; the plan's
cache model is identical in both modes.

The guest sees exactly what `spore run --image X --save` sees today
(`spore_rootfs=1 spore_rootfs_rw=1`), so no guest/initrd changes are expected;
verifying that the init path mounts root rw, that `fsfreeze` is available in
the target base (util-linux is essential in Debian), and that
`resize2fs`-grown filesystems boot cleanly is part of the milestone's
definition of done. A base without `fsfreeze` fails closed with an error
naming the requirement, like the `tar` requirement for COPY.

## COPY Semantics

`COPY` goes **through the guest**, inside the same persistent build-VM
session as `RUN`, rather than host-side ext4 surgery:

1. On the host, resolve sources against the context (no `..` escapes, no
   absolute sources — fail closed), and pack them into an uncompressed tar
   stream: entries renamed to their destination paths, uid/gid forced to 0:0,
   mode bits preserved, symlinks preserved as symlinks, hardlinks preserved,
   xattrs (`security.capability`) carried through, directory entries included
   so empty directories survive.
2. Send the tar to the step driver as a byte-counted `COPY` payload over the
   existing vsock `spore_stream_v1` exec stdin (flow-controlled stdin frames
   already exist for interactive runs); the driver runs `tar -xf - -C /`
   (with Docker merge semantics: existing files overwritten, directories
   merged, destination parents created). This needs a file-backed stdin
   source alongside the terminal-backed `RunStdinControl` — a builder-side
   extension, no protocol or device model change. Rejected transports:
   `--inject` (capped at 16MiB total) and a second virtio-blk device (the
   device model is frozen per `SECURITY.md`/`AGENTS.md`).
3. Checkpoint exactly as RUN does (freeze, reflink clone, step record).

Corollary: the parent rootfs must provide `tar` (and a GNU/busybox tar with
xattr support for the `security.capability` case). The Debian-based target
base does; a base without it fails the COPY step closed with an error naming
the requirement.

Why the guest and not `debugfs` writes or host staging: a real Linux kernel
applies ownership, modes, symlinks, hardlinks, and xattrs natively and
correctly, with no root requirement on the host and no macOS case-sensitivity
or metadata hazards. `debugfs -w` scripting for arbitrary tree merges
(overwrite-vs-merge, unlink-before-write, hardlinks) is a large correctness
surface for no architectural payoff. With the persistent session the guest
boot is already amortized across the whole build, so COPY's marginal cost is
the tar stream plus one freeze/clone checkpoint. Host-side COPY (writing
directly into the ext4 without the guest) stays a documented follow-up for
the case where a COPY is the *only* uncached step; it needs the native ext4
writer's merge machinery and is not v1.

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
check (~1s) + `spore build` cache hit (<1s) + `spore rootfs resolve` — single
digit seconds end to end, versus 5m47s.

## Safety Model And Invariants

- The Dockerfile parser and context walker are new parsers of user-influenced
  input. Per `SECURITY.md`, they ship with fuzz targets in the same change
  (M1 for the parser; the tar *writer* in M3 needs bounded-input tests but is
  not a parser).
- `RUN` executes arbitrary user commands — inside the SporeVM guest, which is
  the existing isolation boundary. The builder adds no new device model, no
  new virtqueue parsing, no monitor changes. The one runtime change is opening
  a build-owned temp file read-write instead of read-only.
- Checkpoints under `build/steps/` are trusted local build state — same trust
  level as the cache directory that holds them — and never leave `build/`.
  Only the final rootfs enters the by-digest cache, through the existing
  verify-at-install path. Step records that reference missing or malformed
  checkpoints are treated as misses, never repaired in place.
- COPY source resolution must not escape the context directory (reject `..`
  traversal and absolute sources after substitution).
- Built-image metadata must not be mistakable for portable OCI provenance:
  `kind: sporevm-built-image-v0`, `layers: []`, and no `rootfs_storage` until
  the lazy upgrade runs. Anything that requires portable storage keeps the
  existing fail-closed/upgrade behavior.
- Machine state and spore format are untouched. No manifest format changes.

## Delivery Strategy

### M1 — CLI, parser, cache skeleton, FROM, metadata-only builds

`spore build` exists. The parser handles the full subset grammar and fails
closed (with tests asserting exact error text) on everything else, including —
temporarily — `RUN` and `COPY` ("not implemented yet" errors distinct from
"unsupported"). `FROM` resolves `--build-context oci-layout://` (through
`importOciLayout`, including the wrapper's patched docker-save layout) and
local refs. A Dockerfile containing only `FROM`/`ENV`/`ARG`/`WORKDIR`/`CMD`
publishes a runnable image: synthesized config digest, image-keyed artifact
(hardlink), metadata sidecar, local ref.

Definition of done:
- `spore build -t local/x:dev --build-context base=oci-layout://… ctx` with a
  metadata-only Dockerfile completes; `spore run --image local/x:dev -- 
  /bin/true` boots it and env/workdir from `ENV`/`WORKDIR` are visible.
- Second invocation is a full cache hit in <1s (base already imported).
- Parser fuzz target in-tree; `mise run test` and `mise run build` pass.

Ceiling proven: cached metadata-only build <1s; base import cost paid once.

### M2 — RUN via the persistent build-VM session

The session executor: reflink clone of the deepest checkpoint,
headroom/resize2fs, rw rootfs boot (runtime_disk change), the step driver
over `spore_stream_v1` (file-backed stdin source), `/bin/sh -c` steps with
env/workdir/network, freeze/clone/thaw checkpointing (including the
virtio-blk drain), final-only blake3 + install, streamed step output,
non-zero-exit failure path with cleanup.

Scaffolding note: if `docs/plans/unified-chunk-disk.md` is adopted, M2's
terminal full-image blake3 is transitional — its U4 replaces it with a
snapshot-index identity. The flat `.ext4` checkpoint clones survive: under
that plan's durable-index invariant, intermediate step checkpoints remain
index-less local flat clones; only the final artifact becomes chunks + an
index. The freeze/drain protocol and session structure carry over unchanged,
so keep the quiesce logic separable from the finalize/hash logic.

Definition of done:
- `FROM base` + `RUN apt-get update && apt-get install -y …` builds against
  the real Buildkite base OCI layout; the result boots; installed packages are
  present.
- Two consecutive RUNs execute in one guest boot with a checkpoint between
  them (asserted via profile output).
- Rebuild without changes: cache hit, no VM boot, <1s.
- Changing the second RUN string resumes from the first RUN's checkpoint —
  one boot, one step re-executed.
- A failing RUN reports the exit code and instruction, leaves no step record
  for the failed step, leaves no live temp files; earlier checkpoints remain
  usable.
- A checkpoint taken mid-build boots and fsck's clean when cloned and run
  directly (freeze correctness smoke).
- resize2fs-grown rootfs boots and fsck's clean (smoke assertion).

Ceiling proven: uncached build = one boot + command time + one final hash
(~15s fixed per build); cached RUN ≈ 0.

### M3 — COPY and context hashing

Context walker + content hashing (sorted, path/mode/type/content), tar
assembly with forced 0:0 ownership, driver-side extraction with merge
semantics inside the same session, `*` globs, step records per COPY.

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
refresh) ≤2s cold-stat, target <1s; uncached COPY ≈ tar-stream + extract +
one freeze/clone checkpoint (~0.1s), boot and hash amortized per build.

### M4 — Wrapper switch and benchmark

Patch `bin/buildkite-spore`: replace buildx/import-tar with `spore build`,
make `prepare_context` incremental/clonefile-based. Add build profiling
phases (see Verification) and record before/after in `docs/benchmarks.md`.

Definition of done:
- `buildkite-spore build` (cached) completes in single-digit seconds wall
  clock, from the observed 5m47s baseline, with `spore build` itself <1s.
- `buildkite-spore start` boots the built image, `setup-spore` reaches
  `/tmp/sporevm-buildkite/ready`, and `buildkite-spore rspec <known-good
  spec>` passes — the rootfs is proven equivalent for the real workload.
- Uncached full build wall clock recorded; target ≤ current uncached path.
- Benchmark script lives in `scripts/` and runs identically by hand and in CI
  where hardware allows.

### M5 — Ergonomics and hardening (follow-ups, ordered by need)

- `.dockerignore` support and `spore build .` with `-f` defaults.
- Per-file context hash cache keyed by (path, size, mtime, inode) so warm
  context hashing is stat-only.
- `spore build prune` / step-cache GC (checkpoints are ~8G logical each;
  reflink keeps physical cost near-delta on APFS, but Linux non-reflink
  filesystems pay full copies — GC matters there).
- Dirty tracking and incrementally maintained chunk indexes: O(dirty)
  checkpoint/finalize identity and incremental chunk-store maintenance.
  Specified in `docs/plans/unified-chunk-disk.md`, which depends on M2's
  persistent session. Deliberately not v1.
- Host-side COPY fast path (apply a COPY without booting the session when it
  is the only uncached step), once the native ext4 writer's merge machinery
  exists.
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
  corrupted record ⇒ miss; atomic write (no partial records after simulated
  crash between install and record).
- Executor: exit-code propagation, env/workdir application, network
  on/off, headroom growth, failure cleanup.
- COPY matrix as listed in M3, plus context-escape rejection tests.
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
spore build profile: phase=session_start clone_ms=… resize_ms=… boot_ms=…
spore build profile: step=3 kind=RUN cache=miss exec_ms=… freeze_ms=…
  checkpoint_clone_ms=…
spore build profile: phase=finalize shutdown_ms=… blake3_ms=… install_ms=…
spore build profile: phase=publish ms=…
spore build profile: phase=total ms=…
```

Benchmark plan (M4, recorded in `docs/benchmarks.md`):

| Scenario | Baseline (buildx+import) | Target |
| --- | ---: | ---: |
| Fully cached wrapper rebuild | 347s | ≤10s wall, `spore build` ≤1s |
| One trailing RUN changed | ~347s | ≤ command + ~15s (boot + final hash) |
| One context file changed | ~347s | ≤ COPY apply + ~15s |
| Fully uncached (base cached) | ~347s | ≤ baseline; stretch: BuildKit-competitive (one boot + work + one hash) |
| Base image changed | ~347s + base | ≤ baseline (import once, steps rerun) |

Each row measured with the profile phases above plus wall clock, on the same
machine as the 5m47s observation, and validated by booting the result and
running the Rails spec smoke.

## Resolved Decisions

- Checkpoints, not layers: `spore build` produces a single flat rootfs; there
  is no layer composition mechanism and no requirement to export Docker
  layers back out (no two-way door). Intermediate states exist only as
  step-key-addressed cache checkpoints; storage sharing comes from
  reflink/COW locally, and chunked CAS via dirty-extent tracking is the
  follow-up path to finer-grained, shareable checkpoints.
- Execute both RUN and COPY inside one persistent build VM per build, with
  freeze/reflink-clone/thaw checkpoints between steps. Rejected: host-side
  `debugfs` writes for COPY (correctness surface too large), COW-overlay
  flattening (needs a new export API for strictly less benefit than direct
  rw clones), clone-boot-commit per step (kept only as the recorded de-risk
  fallback — same cache model, ~15s per step instead of per build).
- Writable clone instead of COW overlay for the session disk: reflink makes
  the clone free, removes the flatten pass, and reuses the existing
  `spore_rootfs_rw` guest behavior.
- Index the final rootfs only; intermediates are addressed by step key, not
  content identity. Child identities are recorded outcomes; no determinism
  requirement on guest writes. Cache keys, not artifacts, carry determinism.
- Default `--network spore` for RUN (Docker parity; the target Dockerfile
  needs apt/curl). `--network none` for hermetic builds.
- `/bin/sh -c` for RUN, not `-lc` (Docker parity).
- Synthesized sha256 config digest reuses the existing local-ref and
  image-keyed cache machinery rather than inventing a parallel ref namespace.
- ARG over-invalidation (all declared args key all later exec steps) accepted
  for v1 simplicity; the target Dockerfile passes no build args.
- Grow-only disk headroom in v1; no shrink pass.

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

## Key Learnings From Pressure-Testing

- The ext4 free-space problem is the biggest silent correctness trap: imported
  bases are sized to content, so the first apt-get in a RUN would ENOSPC.
  The plan makes headroom a first-class, tested step (clone → grow →
  resize2fs → boot) rather than an incident discovered in M4.
- Guest-side COPY looked expensive at first (a VM boot to copy files) but
  removes the entire macOS host-filesystem fidelity problem (case
  sensitivity, ownership without root, xattrs); with the persistent session
  the boot is amortized across the whole build, so the objection dissolved.
- The first design (clone-boot-commit per step, content-hashed
  intermediates) paid ~15s of boot+hash per uncached step — real but
  limited. Recognizing that intermediates never need content digests (only
  the final published rootfs does) unlocked the persistent-session model:
  the per-build fixed cost is one boot plus one hash regardless of step
  count, and "layers" collapse into cache checkpoints.
- Checkpoints are ~8G logical *per exec step*. On APFS reflink keeps
  physical growth near the delta; on Linux without reflink the step cache
  can eat disk quickly. GC/prune is deliberately scheduled (M5) and the risk
  is documented rather than discovered. Dirty-extent CAS (M5) is the
  longer-term answer to checkpoint granularity and cross-machine sharing.
- The cached path must be fast *end to end*, not just inside `spore build`:
  the wrapper's `rm -rf` + 573M context copy would have silently kept the
  rebuild at ~30s. M4 explicitly owns the wrapper-side incremental context.
- Docker cache-semantics fidelity matters more than feature breadth: the test
  plan pins one golden test per invalidation rule so that "cached" never means
  "stale" — the failure mode that would destroy trust in the builder fastest.
