---
status: active
last_reviewed: 2026-07-17
spec_refs:
  - docs/rootfs.md
  - docs/filesystem.md
  - docs/spore-format.md
  - SECURITY.md
  - src/rootfs.zig
  - src/rootfs_cache.zig
  - src/rootfs_cas.zig
  - src/disk_index.zig
  - src/chunk_mapped_disk.zig
  - src/build.zig
  - src/build/cache_mount.zig
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

# Spore-Native Dockerfile Builder Compatibility Roadmap

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
> **Capacity update (2026-07-11).** Build cache v7 introduced separate rootfs
> capacity preparation; current cache v9 retains that contract and adds typed
> COPY destination policy plus ordered default RUN cache-mount identity. The automatic policy is the
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

Evolve `spore build` from a single-stage recipe runner into a generally useful
builder for stable, isolated Linux Dockerfiles. The target is the standard
stable `docker/dockerfile` frontend used by ordinary modern builds: multi-stage
planning, target selection, cross-stage copies, common metadata instructions,
remote bases and inputs, heredocs, COPY flags, and non-privileged mounted RUN
operations.

Compatibility has a precise boundary. When Spore accepts a Dockerfile feature,
it must produce the same final filesystem and OCI runtime configuration as the
selected Dockerfile frontend, and its cache must be sound: a cache hit must
never return stale or semantically different output. Spore may invalidate more
work than BuildKit, use different artifact identities, and omit Docker layer
and exporter behavior. That lets Spore remain a rootfs-native builder rather
than becoming an OCI layer engine while still making existing Dockerfiles run
correctly.

The first useful expansion is ordinary multi-stage application builds. A Go,
Rust, Node, or similar builder stage should be able to copy its result into a
small runtime stage with no Dockerfile rewrite. BuildKit-only optimization,
privileged host integration, arbitrary frontend plugins, and raw credential
mounts are explicit non-goals. The exact unmodified Buildkite `ci` target at
revision `fb742fd5291244e2a1b9c174112f23e2a1581217` is the north-star oracle for
ordering the remaining work: after each general slice lands, its next grounded
failure determines what to consider next. The workload does not define
Buildkite-specific product behavior, cache types, or compatibility shortcuts.

An upstream stable-runtime target remains a valid interim way to unblock the
Buildkite cache-layering experiment. It does not replace this roadmap and adds
no Docker-specific policy to SporeVM.

## Problem

The current builder is intentionally linear:

- one mutable build state;
- one `FROM` resolved from a local image or named OCI layout;
- ordered `RUN`, `COPY`, `WORKDIR`, and metadata updates;
- every rootfs-changing step keyed by its parent rootfs index;
- one persistent VM from the first cache miss to the end of the build.

That model proved the rootfs-native cache and execution path, but it excludes
the normal structure of modern Dockerfiles. Even a basic compiled application
usually has two stages and a `COPY --from`. Larger applications use named
targets, automatic platform arguments, heredocs, ownership flags, remote bases,
and cache or bind mounts. Accepting their syntax without representing their
stage and mount semantics would create builds that appear successful but are
incorrect or unexpectedly stale.

The missing work falls into three different categories:

1. **Frontend compatibility:** parse directives, instruction forms, flags,
   JSON arrays, heredocs, variable expansion, and stage references.
2. **Result compatibility:** construct the same selected stage filesystem and
   OCI runtime configuration, including correct ownership, mount exclusion,
   and metadata inheritance.
3. **Cache compatibility:** identify every persistent and ephemeral input so
   reuse is sound. Exact BuildKit cache keys and cache-hit performance are not
   required; conservative invalidation is acceptable.

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

## Current Contract And Progress

- No BuildKit compatibility beyond the stated subset. The current subset accepts source-spanned
  multi-stage `FROM … AS`, reachable-target planning, `scratch`, public
  registry/local/named-context bases, previous-stage inheritance, literal
  `COPY --from`, result-correct cross-stage `COPY --link`, `--target`, and final
  `ENTRYPOINT`/`CMD` publication. Local-context `COPY --link` and COPY flags
  (`--parents`, `--chown`, `--chmod`), RUN mounts other than bounded default
  `type=cache,target=...`, immutable default read-only context-file
  `type=bind,source=...,target=...`, and one exact optional-absent `type=ssh`
  declaration, local `ADD`, ADD flags
  other than numeric `--chmod`, RUN heredoc forms other than one unquoted,
  non-chomping shell body, COPY heredoc forms other than one unquoted
  non-chomping source, `USER`, `VOLUME`, `EXPOSE`,
  `HEALTHCHECK`, and `ONBUILD` still fail closed. C2 now also accepts bounded
  non-empty JSON-array `RUN` and executes
  its exact argv with Docker-compatible PATH lookup and no implicit variable
  expansion. Effective RUN environments normalize duplicate inherited keys
  with runc's last-value-wins rule before cache hashing and guest serialization.
- No replacement for the wrapper's preliminary `docker build --target ci` of
  the Buildkite app image. That Dockerfile uses `syntax=docker/dockerfile:1.20`
  features that remain outside the subset, including broader heredoc and mount
  forms plus credential-bearing SSH behavior. The base image keeps arriving as an OCI
  layout via `--build-context`.
- The unchanged Buildkite `ci` target is also exercised independently as a
  read-only prioritization oracle. Its first grounded failure may identify C2,
  C3, or C4 work, but does not move mounted RUN or remote ADD semantics into
  C2. The merged exec-form RUN contract passed independent manual acceptance
  on exact main `606a7a24`; its packaged and Linux ARM64/KVM proofs closed the
  gate for the expansion foundation.
- The first post-merge oracle run was pinned to SporeVM
  `606a7a24c8ae77ffd81d1e6c533685122c2185ee` and Buildkite
  `fb742fd5291244e2a1b9c174112f23e2a1581217`, tree
  `3cffc0c8aee0bb8871ecd293a732529fea24d214`, with Dockerfile SHA-256
  `36867efe6eef1e96da5115aa91df0d087be61763c0097846a971d8709e659a2b`.
  Full-file parsing stopped at Dockerfile line 42 on a mutable public HTTPS
  `ADD`; the URL and destination also require builder-owned expansion and
  automatic `TARGETOS`/`TARGETARCH`. No fetch, cache write, or VM boot occurred.
  The syntax 1.20 directive was accepted, while C3 mounts and SSH remained
  unreached. The oracle removed its task-owned scratch afterward, leaving no VM
  or task-owned runtime/cache state.
- The expansion/platform foundation landed as PR #498 at
  `da69aefc918229c8fff810c16b0977e155c2f3ae`. The independent unchanged-oracle
  rerun against that exact main and the same frozen Buildkite input again
  stopped at line 42 before network or VM startup, proving that the next
  boundary remained the narrow public HTTPS ADD slice rather than a regression
  in C2 expansion.
- C4 now accepts exactly one public HTTPS URL with a literal scheme/authority
  and expanded path/query plus one expanded destination. It always refetches
  and hashes the actual bytes before cache
  lookup, applies an opaque regular file through the shared COPY path, and
  accepts an optional instruction-expanded numeric mode from `0` through
  `07777` with default `0600`. It retains HTTP, credentials, Git, other flags,
  symbolic modes, unpacking, and special files as unsupported behavior.
- The public HTTPS ADD slice landed as PR #501 at
  `5cf5dd3e30b7dfaa4800638c59083c2af8b7b24a`, tree
  `59691bddf136e7d512c98a66a0006c5a605db537`. The unchanged frozen Buildkite
  oracle then passed both line-42 ADD instructions during full-file parsing and
  stopped at line 72 on
  `COPY --link --from=test-engine-client /usr/local/bin/bktec /usr/local/bin/bktec`.
  No fetch, cache mutation, or VM boot occurred; C3 mounts, later `ADD --chmod`,
  and SSH remained unreached. The oracle removed its isolated task state after
  recording log SHA-256
  `e207c09bb97c01a1717aadf131819e4e951cb022842587072f444eac3e2d6cde`.
- Cross-stage `COPY --link[=true]` now applies the copied result as if it were
  built on scratch before merging above the current parent: lower destination
  symlinks are not followed, conflicting lower files/directories are replaced,
  and matching directories merge. `--link=false` retains ordinary COPY
  behavior. Spore conservatively keeps the current parent in cache identity;
  it does not claim BuildKit layer rebasing or parent-independent reuse.
- Cross-stage COPY link support landed as PR #502 at
  `b4833aa9f6d697cb44e247fba77d15cbe0d904ec`, tree
  `16c805dedcd845991944bc18d04cdfaf881019b6`. The unchanged frozen Buildkite
  oracle then passed line 72 during full-file parsing and stopped at line 80 on
  `ADD --chmod=0644 https://www.postgresql.org/media/keys/ACCC4CF8.asc
  /etc/apt/keyrings/pgdg.asc`. No remote fetch, image resolution, VM boot, or
  cache mutation occurred; C3 mounts at line 82 remained unreached. Merged-main
  Buildkite #1385 subsequently passed that exact merge, including Linux
  ARM64/KVM conformance, before the numeric remote ADD chmod slice began.
- Numeric remote ADD chmod landed as PR #504 at
  `3da9e35175098b477d01413f0e04bfaaccbf63a6`, tree
  `e0bb97df5bdb9d62abba06f21c780386e9e82a16`. The unchanged frozen Buildkite
  oracle then parsed through line 80 and stopped at line 82 on three
  `RUN --mount=type=cache,target=...` flags with omitted IDs and sharing. No
  remote fetch, image resolution, VM boot, or cache-volume creation occurred.
  Merged-main Buildkite #1388 passed that exact merge before this C3 slice
  began. Live main then advanced to `c3e16ea12ba5f6eb10276feeafec4f7d6f208dfe`
  through PR #503; its chunk-sealing and zero-length virtio-blk reporting
  changes do not overlap the cache-mount frontend, store, or guest lifecycle.
- **Landed C3 cache slice:** accept multiple default
  `RUN --mount=type=cache,target=...` mounts. The omitted ID is
  `path.Clean(expanded target)` before a relative target is joined to
  `WORKDIR`; aliases therefore select one BLAKE3-named directory inside one
  aggregate host-local ext4 disk and one exclusive store lock. The guest mounts
  targets in instruction order, removes them in reverse order after RUN
  descendant cleanup, syncs and unmounts the cache disk, removes only target
  directories it created, and permits rootfs freeze only after successful
  teardown. Cache writes survive failed RUNs and later builds but never enter a
  rootfs checkpoint or portable manifest. Explicit IDs, non-default sharing,
  nested or duplicate targets, and other runtime mount types remain
  fail-closed; the one optional-absent SSH declaration creates no runtime
  mount.
- **Current C3 context-bind slice:** accept only default read-only binds of
  literal regular files from the immutable build context. Source and target
  expand from the instruction-start snapshot, normalize before planning, and
  enter RUN identity with source mode and content digest. Captured mtime is
  transport metadata rather than semantic RUN identity, matching BuildKit's
  mtime-only cache hits. A miss captures the file and its race-checked
  nanosecond mtime into the v2 identity of the existing read-only context disk;
  disks without captured mtime retain v1, and ordinary entries retain their
  zero-timestamp behavior. The guest attaches only that
  file to the operation-owned sandbox, then unmounts it and removes owned
  target scaffolding before checkpoint. Directories, symlinks, special files,
  writable/custom binds, stage/image/named-context sources, and overlapping
  targets remain fail-closed.
- No OCI image/layer output. `spore build` produces Spore rootfs artifacts and
  local refs, not pushable OCI images.
- No flat checkpoint store and no full-image hash fallback in the executor.
  Intermediate and final build states are rootfs CAS indexes produced through
  the unified `ChunkMappedDisk` snapshot path.
- No cross-machine or shared build cache. The step cache is local, same trust
  model as the existing rootfs CAS cache.
- No new persistent device type or portable machine-state contract. The build
  VM uses the existing device set and may attach bounded transient read-only
  virtio-blk context or stage/rootfs disks. A non-resumable rootfs-growth
  session temporarily offers `VIRTIO_BLK_F_WRITE_ZEROES` on the existing root
  block device. The guest contracts are `spore-rootfs-grow-v1`, the `fsfreeze`
  checkpoint handshake, and fixed-shape RUN/COPY requests over the existing
  exec stream.
- A 2026-07-16 security review proved that a cgroup plus chroot is not a RUN
  sandbox: attacker-controlled build code could traverse the agent's procfs
  through `/proc/1/root` and could open auxiliary virtio block devices exposed
  by the rootfs devtmpfs. The selected prerequisite is a dedicated,
  operation-owned RUN isolation view. The cache-mount prototype and exploit
  evidence are preserved separately and remain unpublished; `RUN --mount`
  stays rejected until this foundation lands and is independently accepted.

C0 closes the known checkpoint, resize, resource-envelope, matcher, and cache
lifecycle gaps in the original single-stage subset. C1 adds ordinary
multi-stage planning and immutable cross-stage COPY without widening the
device model or cache authority. The same-VM smoke and differential harness
cover the implemented subset on Linux ARM64/KVM. Each newly accepted metadata
instruction must extend final image configuration inheritance and the oracle
together.

## Compatibility Contract

### Accepted features

For every accepted instruction or flag:

- the entire Dockerfile is parsed and planned before any stage executes;
- the selected target's reachable stage closure is known before execution;
- final paths, types, content, mode, uid/gid, symlink target, and relevant
  extended metadata match the Docker/BuildKit oracle;
- final OCI runtime configuration and inheritance match the oracle;
- ephemeral mount data, credentials, SSH state, and helper sockets are absent
  from every rootfs checkpoint and final image;
- all semantically relevant inputs are represented in cache identity or cause
  conservative invalidation;
- unsupported values or combinations fail closed with file, line, instruction,
  and actionable reason.

Filesystem and config parity are required. These differences are allowed:

- rootfs ext4 allocation, inode numbers, and timestamps that Docker does not
  define as build inputs;
- Spore rootfs index and image identities;
- additional cache misses caused by conservative keys;
- sequential execution of independent stages;
- absence of Docker layers, history, registry cache manifests, and exporter
  metadata.

No accepted option may silently downgrade result semantics. A flag whose only
portable effect is cache performance may use a more conservative cache
implementation, but its filesystem behavior still has to match. For example,
`COPY --link` may initially depend on the current parent and therefore re-run
more often than BuildKit, but it must still enforce `--link` destination and
symlink rules and must never reuse stale output.

### Dockerfile frontend versions

The native frontend supports the standard `docker/dockerfile` dialect. Leading
`# syntax=docker/dockerfile:<version>` and `# escape=<character>` directives
are parsed in Docker's directive window and included in plan identity.

- Known stable standard versions are accepted when every used feature is
  implemented.
- A known directive may contain unsupported instructions; those instructions
  fail individually during planning.
- Custom frontend image references, `-labs` features, and unknown directive
  forms fail closed by product policy.
- Accepting a newer directive never implies support for every feature of that
  frontend version.

The compatibility matrix and tests, rather than a broad version claim, are the
source of truth.

### Planned CLI surface

Existing options remain. New options land only with the feature that consumes
them:

```bash
spore build \
  -t local/app:dev \
  --target runtime \
  --platform linux/arm64 \
  --build-arg VERSION=dev \
  --network spore \
  --memory 4gb \
  --vcpus 4 \
  --timeout 30m \
  --ulimit nofile=65536:65536 \
  .
```

Resource controls reuse Spore's memory, vCPU, and duration parsers and expose a
bounded `nofile`-only ulimit contract. RUN cache identity includes resolved
memory, vCPU, and `nofile` values because commands can observe them; timeout is
host-only, applies independently to each Dockerfile instruction, and never
publishes a failed or timed-out operation. Multiple guest requests belonging
to one COPY instruction share its timeout budget. The core
builder does not add raw `--secret` or `--ssh` host-input options. Do not expose
an option before its cache, snapshot, and failure semantics are implemented.

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

Before the first executor-backed instruction, the current builder resolves a
typed v9 `PREPARE` key, retaining the v8 capacity contract, from the parent
index, exact target, and the exact managed
kernel/initrd plus growth-protocol producer identity. A hit becomes the parent
for ordinary Dockerfile keys. On a miss, the same VM that will execute the
remaining steps grows the clean-zero chunk map. Before the first writable
mount, the managed initrd rejects journal, recovery, error, and pending-orphan
state and revalidates that source state around the ext4 resize ioctl. The
builder then freezes and snapshots the prepared filesystem, publishes the
completeness stamp and `PREPARE` record, thaws, and continues with step zero.
The selected image needs no `/bin/sh` or `resize2fs` for preparation.

- Build ordinary modern multi-stage Linux Dockerfiles without source rewrites.
- Preserve Docker-equivalent final filesystem and OCI runtime configuration for
  accepted features.
- Keep cache reuse sound while allowing conservative over-invalidation.
- Retain the current rootfs-native artifact model: immutable CAS-backed stage
  outputs and no mandatory tar/layer conversion boundary.
- Make stage, operation, mount, and cache lifetimes explicit in the planner.
- Reuse the persistent build VM and O(dirty) checkpoints where doing so remains
  correct and measurably useful.
- Keep all guest/device behavior backend-neutral across KVM and HVF.
- Fail before execution on unsupported frontend semantics.
- Grow support through representative public fixtures and differential
  Docker/BuildKit oracles rather than one private workload.
- Use the exact unmodified Buildkite `ci` target at pinned revision `fb742fd` as
  an ordering and final-acceptance oracle, while implementing only general
  Dockerfile semantics and keeping SSH or application-specific behavior out of
  SporeVM unless a separate product decision explicitly changes that boundary.

## Non-Goals

- No byte-for-byte BuildKit cache-key or layer identity compatibility.
- No OCI layer/history generation, registry push output, zstd exporter, or
  registry cache import/export in this plan.
- No cross-machine shared Spore build cache. Cache records and writable cache
  mounts remain in the local host trust domain initially.
- No arbitrary Dockerfile frontend plugins or frontend gateway protocol.
- No custom frontend images, `dockerfile:labs`, nightly syntax, or frontend
  build-check framework. Only the supported stable `docker/dockerfile` dialect
  is accepted.
- No Windows containers or non-Linux filesystem semantics.
- No foreign-architecture execution or emulation. A reachable stage must be
  executable on `linux/arm64`; platform expansion requires a separate backend
  plan.
- No Docker daemon, Compose, package-manager, or language-specific behavior in
  the builder.
- No automatic translation or best-effort execution of unsupported features.
- No `RUN --device`, `RUN --security=insecure`, `RUN --network=host`, arbitrary
  host paths, host devices, Docker socket mounts, or privileged build mode.
- No Docker-style raw secret-file mounts, PEM injection, or SSH-agent mounts.
  A future named credential broker would require a separate security plan.
- No remote Git `ADD`, Git build contexts, `ADD --keep-git-dir`, or remote
  archive `ADD --unpack` in this roadmap.
- No deprecated `MAINTAINER`; use OCI author labels.
- No Docker anonymous-volume creation, health supervisor, port publication, or
  stop-signal runtime orchestration. Common metadata instructions are preserved
  in image config only.
- No parent-independent `COPY --link` layer rebasing or BuildKit-exact cache
  mount scheduling. Spore may conservatively depend on the parent and serialize
  cache writers.
- No performance promise that every BuildKit cache hit is also a Spore cache
  hit. Correct conservative execution is preferred over speculative reuse.

## Target Architecture

The current instruction slice becomes a frontend and graph planner feeding a
typed operation executor:

```text
Dockerfile bytes
    │
    ▼
versioned native frontend
    │  directives, spans, stages, typed flags, heredocs
    ▼
target-pruned stage graph
    │  base edges, stage-copy edges, mount/input dependencies
    ▼
topologically ordered stage plans
    │
    ├── metadata operations
    ├── RUN operations with explicit mounts/network/user/shell
    ├── context COPY/ADD operations
    └── stage COPY operations
    ▼
Spore stage executor
    │  local cache lookup or persistent build VM
    ▼
immutable {rootfs index, image config} stage artifact
```

### Native frontend and intermediate representation

Continue with the native Zig frontend. Parsing Dockerfile grammar is smaller
than implementing its execution model, the existing parser already has fuzz
coverage and bounded diagnostics, and an upstream BuildKit/LLB helper would add
a second runtime and a much broader generic operation contract without
implementing Spore's mounts or cache policy.

| Instruction | Support |
| --- | --- |
| `FROM [--platform=linux/arm64] <source> [AS <name>]` | `scratch`, previous stage, named `--build-context` (OCI layout), local ref, public registry ref, or digest ref. Other platforms fail closed. |
| `RUN [--mount=type=ssh] [--mount=type=cache,target=<path>]… [--mount=type=bind,source=<file>,target=<path>]… <shell>` / `RUN … ["argv", …]` | shell form executes as `/bin/sh -c`; bracket-prefixed text falls back to shell form when it is not valid JSON. Exec form preserves a bounded non-empty JSON string array, rejects valid arrays containing non-string values, and searches PATH only when argv zero contains no slash. Cache mounts require omitted ID/sharing. Context binds accept only literal regular files from the immutable build context and the default read-only policy on ordinary shell-form RUN; exec-form and heredoc combinations remain fail-closed. Normalized source/target, mode, and bytes are cache identity. Bind transport inodes, mountpoints, and setup scaffolding never enter the rootfs snapshot, while ordinary files written by RUN remain persistent output. One exact default SSH declaration is accepted only as optional-absent compatibility: it adds the inert BuildKit `SSH_AUTH_SOCK` value when the effective RUN environment lacks the key, but creates no socket or credential path. Writable/custom, directory, stage/image/named-context, tmpfs, secret, credential-bearing SSH, and per-instruction network forms remain rejected. |
| `RUN [--mount=type=cache,target=<path>]… <<NAME` | one unquoted, non-chomping heredoc token as the complete RUN command. A non-empty body without a leading shebang is preserved byte-for-byte, including its final newline, and executes through the ordinary shell RUN path. ARG/ENV, quoting, escaping, unset variables, and parameter operators are therefore evaluated by the guest shell, not the builder-owned operand expander. Shell-prefix, quoted, chomping, multiple, empty, shebang/direct-exec, and exec-form heredocs fail closed. |
| `COPY [--link[=<bool>]] [--from=<stage-or-context>] <src>… <dest>` | context-relative or build-input-relative expanded source/destination operands, including files and directories. `--from` remains literal, matching BuildKit. `--link=true` is accepted only with `--from` and uses no-follow scratch-merge destination behavior; `--link=false` retains ordinary cross-stage COPY behavior. Local-context `--link` and other COPY flags fail closed. |
| `COPY <<NAME <dest>` | one unquoted, non-chomping inline source with no flags. The body preserves its final newline and quote bytes while expanding stable ARG/ENV expressions from the instruction-start snapshot. It becomes one root-owned `0644` regular file; a directory destination uses `NAME` as its basename. Multiple, mixed, quoted, and chomping heredocs fail closed. |
| `ADD [--chmod=<octal>] <https-url> <dest>` | one public HTTPS URL with literal scheme/authority and expanded path/query plus one expanded destination. The opaque response is always refetched, bounded, and content-addressed. Numeric chmod expands at instruction start and must resolve from `0` through `07777`; other flags, symbolic modes, local/Git sources, credentials, and archive extraction fail closed. |
| `ENV K=V` / `ENV K V` | build env + final image config. |
| `ARG K[=default]` | value from `--build-arg` or an expanded default; unset values expand to empty unless a supported operator supplies another result. |
| `WORKDIR /path` | affects `RUN` cwd, `COPY` relative dest, final config. Relative and parent components normalize from the current directory within the guest root, and the result is created in the guest if missing, matching Docker. |
| `CMD ["…"]` / `CMD <shell>` | final image config only; bracket-prefixed invalid JSON is shell form, while valid JSON containing non-string values is rejected. |
| `ENTRYPOINT ["…"]` / `ENTRYPOINT <shell>` | final image config only; bracket-prefixed invalid JSON is shell form, while valid JSON containing non-string values is rejected. |
| comments, line continuations, `${VAR}`/`$VAR` substitution in supported instruction arguments | The leading directive window accepts the stable Dockerfile syntax directive and backslash/backtick escape directives. Removing an escape and physical newline inserts no bytes, single quotes remain literal, double quotes expand, and unsupported syntax frontends fail closed. |

Builder-owned variable substitution applies to `FROM`, `ENV`, `ARG` defaults,
`WORKDIR`, `COPY` source/destination arguments, and the accepted `ADD` numeric
mode, URL path/query, and destination, plus accepted context-bind source and
target operands, using the declared
`ARG`/`ENV` state. `COPY --from` remains literal. `CMD` and `ENTRYPOINT` retain
variables for runtime. Shell-form `RUN`, including the accepted simple RUN
heredoc, is not pre-expanded; its guest shell sees the effective `ARG`/`ENV`
environment and performs shell expansion. That environment and the exact
heredoc body remain cache inputs. Exec-form `RUN` preserves every argv string
literally. The
builder-owned subset accepts `$NAME`, `${NAME}`, `${NAME:-word}`,
`${NAME-word}`, `${NAME:+word}`, and `${NAME+word}`, including nested stable
expansion in `word`. Pattern removal, replacement, required-value, and other
modifiers fail closed in those instruction fields.

## Architecture

New module family, backend-neutral, sibling to the existing rootfs code:

```
src/build_cli.zig        CLI parse + dispatch (registered in src/main.zig
                         next to "rootfs"/"run")
src/build.zig            orchestrator: plan, typed stage transitions,
                         final ref publication
src/build/instruction_transition.zig
                         cache-prefix walk and executor-suffix lowering from
                         one typed RUN/COPY/ADD/WORKDIR transition
src/build/dockerfile.zig subset parser -> []Instruction, fail-closed,
                         fuzz target required (new parser of
                         user-influenced input per SECURITY.md)
src/build/context.zig    .dockerignore-aware context walking, stat-cache
                         memoization, and content hashing for COPY
src/build/context_disk.zig
                         read-only ext4 context disk emission/reuse for
                         executed COPY steps
src/build/cache_mount.zig
                         default cache-ID normalization and identity plus the
                         aggregate ext4 store lifecycle and exclusive lock
src/build/step_cache.zig step-key computation + canonical v9 record adapter
                         shared by cache-hit and GC validation; on-disk records
                         map deterministic parent+instruction inputs to child
                         index_digest outcomes, including the typed v9 PREPARE
                         normalization record
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
    config_env: []const EnvPair, // ordered OCI publication view
    effective_env: []const EnvPair, // last-value-wins expansion/RUN view
    args: []const ArgPair,      // declared ARG values
    workdir: []const u8,        // current WORKDIR
    cmd: ?[]const []const u8,   // CMD, metadata only
};
```

Every value retains source spans for diagnostics. Flags and mount options are
typed during planning rather than re-parsed by the executor. Unknown flags,
duplicates, invalid combinations, and unresolved variables fail before any
stage runs.

The frontend owns Dockerfile syntax and substitution. The planner owns stage
resolution and dependency closure. The executor never receives raw Dockerfile
text as authority; raw/canonical text may still be recorded for diagnostics and
cache migration.

If maintaining native parser conformance later proves disproportionate, an
upstream-frontend adapter can target the same typed plan. LLB is not accepted as
a public or cache format in this roadmap.

### Stage graph and artifacts

Each stage has independent filesystem and image-config state. Its base is one
of:

- a registry/local/named OCI image;
- a previous stage artifact;
- `scratch`.

Global ARGs and automatic platform ARGs are resolved for base selection without
leaking into stage runtime environment unless redeclared according to Docker
rules. `FROM previous-stage` inherits both rootfs and image configuration.
`COPY --from` reads filesystem state but does not inherit source-stage config.
Numeric stage indexes, named stages, named contexts, and external image
references share one explicitly tested resolution namespace; the planner never
guesses after execution has started.

The planner computes the selected target's transitive closure, rejects cycles,
and executes stages in deterministic topological order. Parallel independent
stage execution is deferred until sequential behavior and cache identity are
proven.

All reachable external bases and named image contexts are resolved to immutable
identities before taking the coarse cache lock used during stage execution.
Alternatively, locking may be narrowed to individual cache lookup/publication
transactions. The executor must not hold the current non-reentrant cache lock
while resolving a later stage's remote base.

A completed stage artifact is:

### Step keys

Build cache v9 has two typed derivations in the same record namespace. The
synthetic `PREPARE` operation normalizes capacity before Dockerfile cache keys
are resolved; RUN, COPY, ADD, and WORKDIR then use the prepared child as their
ordinary parent. A key is a cache lookup address, and the record at that address
stores the child `index_digest` produced by the prior successful execution.

```
prepare_key = blake3_framed(builder_version_v9, platform,
                            parent_index_digest, "PREPARE", exact_target,
                            producer_identity)

step_key = blake3_framed(builder_version_v9, platform,
                         prepared_parent_index_digest, instruction_kind,
                         canonical_instruction, input_digest, env_digest,
                         workdir, network_mode, copy_destination_policy,
                         cache_mount_digest,
                         executor_identity)
```

Every field is length-framed, and optional fields carry an explicit presence
tag. `disk_grow_target` is absent from v9 Dockerfile inputs and records. The
producer identity binds the exact kernel and initrd bytes that will boot plus
the growth request, mount/no-lazy-init policy, transient WRITE_ZEROES contract,
and preparation host-contract version. The same exact-byte identity is carried
as `executor_identity` in every RUN/COPY/ADD/WORKDIR key: two producers that happen
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
- `RUN`: the exact canonical shell- or exec-form instruction, the current
  `WORKDIR`, and the network mode.
  The environment digest is an ordered, length-framed sequence of the effective
  last-value-wins `ENV` entries followed by typed `ARG` records (key, presence
  bit, value), including list counts. Raw duplicate `Config.Env` entries remain
  ordered for OCI publication, while equivalent normalized ENV plus typed ARG
  state intentionally shares a digest. The digest distinguishes ENV from ARG state
  and unset ARG from an explicitly empty value, and cannot alias embedded
  newlines with multiple entries. An accepted optional-absent SSH declaration
  adds the resolved effective environment and an explicit
  `ssh_declared_absent` state; future forwarded-agent work cannot alias it.
  `input_digest` is empty.
- `COPY`: the substituted source patterns and dest, the current `WORKDIR`,
  and `input_digest` = the context content hash of the matched sources:
  after sorting by relative path and deduplicating repeated matches, each
  matched entry contributes length-prefixed fields to one BLAKE3 stream:
  `u64le(len(path)) || path || u64le(len(type)) || type ||
  u64le(len(mode)) || mode || u64le(len(payload)) || payload`. The payload is
  file content, symlink target text, or empty bytes for a directory.
  Ownership is not hashed (COPY forces 0:0). mtimes are not hashed
  (Docker parity). A heredoc contributes its delimiter-derived relative name,
  regular-file type, fixed `0644` mode, and BLAKE3 digest of the exact resolved
  body through the same framing; the canonical source, resolved destination,
  workdir, and instruction-start environment digest complete the normal COPY
  key.
- `ADD`: the resolved public HTTPS URL and destination, URL-path or response
  filename, downloaded content digest, validated optional `Last-Modified`,
  resolved numeric mode (default `0600`), current `WORKDIR`, and
  instruction-start ENV/ARG state.
- `ENV` / `ARG` / `CMD`: metadata instructions update the state consumed by
  later execution keys. A changed `ENV` or `ARG` invalidates later `RUN`/`COPY`/`ADD`
  steps, while a final `CMD` keeps the same rootfs `index_digest` and costs only
  a local ref/config re-publish.
- `WORKDIR`: the normalized absolute path and current state key the filesystem
  step that creates the directory. A changed `WORKDIR` publishes a new child
  index and invalidates later `RUN`/`COPY`/`ADD` steps.

### Scheduler and build sessions

`--no-cache` bypasses only RUN/COPY/ADD/WORKDIR record reads. It deliberately still
reads `PREPARE`: forcing Dockerfile execution must not repeat stable
infrastructure normalization, replace the prepared parent with another valid
kernel-produced index, or reintroduce cold resize cost. An isolated preparation
benchmark uses a separate cache instead of a user-facing bypass.

`ARG` follows this simplification: a declared ARG's value enters the effective
environment of every subsequent `RUN`/`COPY`, so changing any declared
`--build-arg` invalidates subsequent execution steps even if unreferenced.
This over-invalidates relative to Docker (which tracks reference), and is
recorded as an accepted tradeoff below.

- parent stage artifact;
- network mode;
- immutable source disks;
- writable cache volumes and their locks;
- resource settings.

Operations with a compatible envelope continue in one persistent VM and retain
the current checkpoint efficiency. A changed envelope ends the session at a
completed checkpoint and starts another from that immutable stage state.
Independent stages execute sequentially at first. Per-RUN network or mount
semantics must never be approximated by applying one policy to an incompatible
whole-stage suffix.

Rootfs growth and filesystem checking move into the initrd or a host/native
storage path. Session startup must be able to grow and mount a `scratch` stage
without executing any program from that stage's rootfs.

### Typed execution operations

A RUN operation records:

- shell or exact argv form;
- effective shell from `SHELL`;
- effective user and groups from `USER`;
- environment and working directory;
- network mode (`spore`/default or `none` only);
- an ordered list of typed mounts;
- resource requirements relevant to execution and cache safety.

A COPY/ADD operation records:

- source kind: context, stage, URL, or local archive;
- immutable resolved input identity;
- destination and destination-shape rules;
- ownership, mode, parents, exclude, link, and follow/extract policy;
- the exact filesystem behavior required at the destination.

Metadata operations update the stage config and, where Docker requires it,
filesystem state. Expand `ImageConfig` and canonical image identity before
accepting instructions that set `Entrypoint`, `User`, labels, ports,
healthcheck, stop signal, or volumes. Imported ONBUILD triggers must be
preserved only so a reachable base containing them can fail closed rather than
silently dropping hidden build behavior.
The import metadata schema is versioned when fields are added so cached bases
that were decoded under the older lossy schema cannot silently masquerade as
complete configuration.
Until non-root RUN execution lands, an inherited or explicit non-root `User`
that would affect an executed operation remains a planning error; Spore must
never silently execute it as root.

### Mount model

The long-term mounted RUN design is one generic execution facility. The table
below is future scope beyond the first accepted cache-only slice:

Every build RUN first enters the same operation-owned sandbox, whether or not
future explicit mounts are present. Its supervisor owns new PID, mount, cgroup,
IPC, and UTS namespaces; makes mount propagation recursively private; and
enters a descriptor-clean rootfs confinement so the initrd and agent mount
tree are unreachable.
The command is PID 1 in its PID namespace and sees a procfs mounted from that
namespace, with the BuildKit read-only and masked proc paths that prevent
guest-global sysctl mutation and access to sensitive kernel pseudo-files. It
also sees a new minimal `/dev` and devpts, read-only sysfs and cgroup views,
and no auxiliary virtio block or console nodes. A cgroup device policy permits
the normal character devices and harmless device-node creation while rejecting
reads or writes of every block device and console alias. A narrow seccomp
policy rejects AF_VSOCK creation, `socketpair(AF_VSOCK)`, and `io_uring_setup`
so the command cannot reach the agent/host control transport or bypass the
socket-family rule asynchronously. The command receives only the pinned
BuildKit-compatible capability set and its intended stdio descriptors.

The supervisor mirrors ordinary exit and signal status. Namespace destruction
owns mount teardown, while cgroup kill-and-empty verification independently
covers success, nonzero exit, signal, timeout, setup failure, and control loss.
Any incomplete setup or cleanup fails the RUN and blocks checkpoint or cache
publication. This foundation adds no Dockerfile syntax, device type, manifest
field, credential authority, or persistent filesystem view.

| Mount | Source | Writable | Snapshot into rootfs | Cache identity |
| --- | --- | ---: | ---: | --- |
| context bind | immutable context capture | no by default | no | resolved content and mount options |
| stage bind | immutable stage rootfs | no by default | no | source stage artifact, path, options |
| tmpfs | empty per operation | yes | no | mount options only |
| cache | local named cache store | yes | no | cache id/options; contents do not make a rootfs hit valid |

All mounts live outside the rootfs disk. The default cache slice mounts the
aggregate in the trusted agent namespace, bind-mounts only selected cache
directories onto confined rootfs targets, and then enters the same
operation-owned RUN sandbox as an unmounted instruction. The sandbox chroot
inherits those selected targets but cannot name the aggregate or sibling cache
keys. After sandbox PID/cgroup teardown, the agent unmounts targets in reverse
order, syncs and unmounts the aggregate disk, removes only target directories
it created, and then permits freeze and snapshot. Cleanup records the
device/inode identity of the mount target and every created component, then
reopens the path without following symlinks; pre-existing symlink ancestry is
rejected before RUN starts. It must remove a created empty
mountpoint, removes empty created ancestors, and preserves the first nonempty
ancestor so ordinary rootfs sibling content survives. Unmount failure, a
nonempty created mountpoint, path replacement, or unverifiable ownership
poisons the guest build session, returns exit 125, and blocks step-record and
ref publication. PID 1 remains alive to drain that failure over vsock while
rejecting every later request, including checkpoint operations.

The first immutable context-bind slice reuses that ownership model for regular
file targets. Full-file planning resolves one literal relative source through
`.dockerignore`; cache preparation hashes its mode and bytes, and miss lowering
seals it into the existing context snapshot before the VM starts. The same
validated stat supplies ext4-range nanosecond mtime and selects the v2 context
disk identity. It is excluded from the RUN key, so an mtime-only change reuses
the cached result while any later forced miss observes the new transport
metadata. Context disks without captured mtime retain byte-identical v1
production, and ordinary entries keep zero timestamps. The strict
v4 RUN request names only a per-capture context-disk path and canonical rootfs
target. The agent opens both endpoints without following symlinks, mounts the
file read-only, and removes only the owned empty-file target plus empty owned
ancestors after reverse-order unmount. Existing regular-file targets are never
removed, and a nonempty owned ancestor preserves ordinary sibling rootfs
content. Any target replacement or uncertain cleanup poisons the same build
session. This adds no host bind, writable source, new disk kind, or portable
mount state.

Immutable bind inputs can reuse the context or stage disks. Writable cache
mounts require a separate local storage contract with explicit ownership,
locking, crash recovery, and GC. Do not emulate cache mounts with directories
inside the rootfs followed by deletion: their blocks would enter intermediate
snapshots and alter later behavior.

The first writable slice accepts only omitted `sharing`, whose BuildKit default
is `shared`; Spore conservatively serializes all access with one exclusive host
store lock. Explicit `sharing=locked`, `sharing=private`, and explicit cache IDs
remain rejected until their ownership and concurrency contracts land. A missing
cache may change command performance and downloads but not permit reuse of an
output produced from semantically different rootfs inputs.

### Credential boundary

The core builder rejects `RUN --mount=type=secret`, credential-bearing SSH
mounts, raw host secret files, PEM inputs, and SSH-agent forwarding. One exact
default `RUN --mount=type=ssh` declaration is accepted only when the caller
supplies no SSH input. BuildKit v0.30.0 makes that optional-absent operation
observable by adding `SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` when the
effective RUN environment lacks the key, even though it omits the socket mount.
Spore matches that precedence for the RUN alone while creating no socket,
`/run/buildkit` path, host input, forwarding transport, guest protocol field,
credential broker, CLI option, or durable state.

The typed plan and cache record carry `ssh_declared_absent`, and the resolved
effective environment remains cache identity. A future operation with a real
agent therefore cannot reuse this result. Options, duplicate declarations,
`required=true`, custom id/target/mode/uid/gid, secrets, and any caller-supplied
SSH input fail during full-file planning. If the command actually requires the
nonexistent socket, its ordinary nonzero RUN result publishes no step or image
record.

A future named credential broker may implement a deliberately different,
mediated contract if real consumers justify it. That work requires a separate
security plan and does not block this roadmap. Dockerfiles that require raw
secret or actual SSH mounts continue to fail during planning.

### Cache model

The existing step cache becomes an operation cache scoped to a stage plan.
Every rootfs-changing operation key includes at least:

```text
builder/cache schema
frontend directives and semantic version
platform
stage identity
parent rootfs index and effective image config
typed canonical operation
resolved immutable inputs
effective env, args, user, shell, and workdir
network and mount options
resource settings that can affect observable output
```

Intermediates are input-addressed by their step key, but their artifacts are
normal rootfs CAS indexes. The step record is not restore authority; it is a
local memo from deterministic inputs to a child `index_digest`. A cache hit
requires the child index to parse, validate against the rootfs descriptor, and
have the already-published completeness stamp. V9 does not repair a missing
stamp during lookup: missing or malformed indexes, missing complete stamps, or
bad records are misses. GC continues to parse older records conservatively and
may retain their complete content, but v8, v7, and v6 records cannot hit v9 keys.

Cache correctness rules:

```json
{
  "kind": "sporevm-build-step-v1",
  "builder_version": "sporevm-build-v9",
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
  "cache_mount_digest": "blake3:…",
  "executor_identity": "blake3:…",
  "created_unix": 0
}
```

Capacity preparation uses the same bounded parser, atomic writer, CAS objects,
completeness stamps, and GC roots rather than a second cache subsystem:

```json
{
  "kind": "sporevm-build-step-v1",
  "builder_version": "sporevm-build-v9",
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

Prefer operation-family semantic versions over one global builder version once
the typed plan lands. A frontend-only change should not invalidate unrelated
executor records, while a changed RUN or COPY contract must not reuse older
outcomes. Add record pruning before repeated compatibility migrations leave
obsolete-but-valid records as permanent CAS roots.

Exact BuildKit cache equivalence is unnecessary. `COPY --link`, unused ARGs,
stage scheduling, and mount caches may over-invalidate provided the result and
reuse remain correct.

### Registry and remote input model

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

Anonymous public bases land first. Docker credential files and helpers are a
separate host-side credential feature; credentials never enter rootfs metadata
or the guest.

Remote URL `ADD` reuses the host fetch policy and verifies downloaded bytes
before cache lookup or immutable build-input publication. The approved mutable
URL contract always performs a fresh GET on each build and reuses downstream
work only when the resolved operands, actual content digest, and validated
optional `Last-Modified` timestamp match. A valid HTTP-date becomes the applied
mtime; an absent or malformed one uses the Unix epoch. A redirect target is revalidated on every
hop but is transport evidence rather than stable cache identity: ephemeral
signed redirect URLs cannot hide changed bytes because the content digest
remains authoritative, and they do not force a miss when the requested URL,
bytes, and persistent metadata are unchanged. `ADD --checksum` remains a
separate later integrity-pinned form. Local tar extraction reuses the bounded,
path-safe rootfs tar machinery and extends its fuzz corpus. Remote Git sources,
Git build contexts, `ADD --keep-git-dir`, and remote `ADD --unpack` remain
unsupported.

## Compatibility Matrix

The matrix records planned result support, not BuildKit layer/export parity.

Uncached steps execute in **one persistent build VM per build**, not one VM per
step. A preparation miss and all remaining RUN/COPY/ADD/WORKDIR instructions share
that VM. A preparation hit becomes the normal Dockerfile cache parent, so a
later Dockerfile miss boots directly from the prepared child with no resize.
Checkpoints freeze the filesystem, drain virtio-blk, seal only changed chunks,
and enumerate one canonical full rootfs CAS index.

## Safety And Correctness Invariants

1. Before the first executor-backed instruction, compute the absolute target
   `max(FROM.logical_size, 16 GiB)`. If no growth is needed, continue directly.
   Otherwise resolve the v9 `PREPARE` key. A valid hit supplies the prepared
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
   metadata chunks, emit the canonical logical index, and publish the
   completeness stamp. Thaw without advancing the Dockerfile step index, then
   atomically publish the typed `PREPARE` record and install the prepared child
   as the live `ChunkMappedDisk` baseline before continuing step zero in the
   same VM. A failed grow, freeze, snapshot, stamp, thaw, or record publication
   executes no Dockerfile step and publishes no destination ref or reusable
   step record; complete orphaned CAS storage remains collectable.
6. For an ordinary Dockerfile executor miss, use the prepared parent through
   the same internal writable-rootfs mode, without the growth-only feature or
   control request. Continue the VM already live after a preparation miss, or
   boot the prepared child once after a preparation hit. The host drives the
   existing initrd agent over bounded `spore_stream_v1` requests:
   - `RUN`: shell form sends a fixed-shape `spore-build-run-v1` request with the
     step's effective env, workdir, and command length, then sends the command
     text as a length-prefixed payload capped at 64 KiB. The driver runs
     `/bin/sh -c` as root (Docker parity: `-c`, not the `-lc` that
     `spore run`'s shell mode uses). Exec form sends `spore-build-run-v2` with
     at most 16 exact argv strings and 4 KiB of decoded argv bytes. The host
     preflights the fully serialized request while constructing the
     source-spanned transition. Exec form invokes no implicit shell, so `$NAME`
     stays literal unless the argv explicitly starts a shell; a slashless
     executable is resolved through the effective non-empty PATH before one
     execution attempt. Lookup skips missing, non-executable, directory, and
     other lookup-time failures, rejects a relative executable match, and
     selects the first executable absolute candidate; failure to execute that
     selected candidate is terminal and never falls through to a later entry.
     Cache-mounted shell or exec form uses the strict `spore-build-run-v3`
     object with its exact bounded mount list. A RUN with context-file binds
     uses strict v4, which adds non-empty ordered captured-source and canonical
     target arrays while retaining the cache list; its selected files already
     reside on the immutable context disk before startup. The shared v2/v3/v4 parser requires every documented field
     appears once, aliases and unknown fields are rejected, arrays have no
     trailing commas, the complete request ends in a newline, and no
     non-whitespace bytes follow the object. Strings preserve valid raw UTF-8
     and decoded Unicode escapes, while invalid UTF-8, embedded NULs, and
     unpaired surrogates fail closed. Both forms stream output, report the exact
     exit code, and use the session's `--network` policy.
   - `COPY`: before boot, the host emits the resolved context entries needed
     by executed COPY steps into a cached read-only ext4 context disk and
     attaches it as an additional virtio-blk device. Per step, the host sends
     one or more fixed-shape COPY control requests. Ordinary COPY and ADD use
     `spore-build-copy-v4`; cross-stage `COPY --link=true` uses strict v5 with
     an explicit `destination_policy=link`. Both name the source disk and
     bounded input index, source subtree, destination, source kind, bounded
     entry count, and optional ADD mtime. The agent recursively copies from the
     selected context or immutable build-input disk into `/mnt/rootfs` using
     the confined destination resolver (see COPY Semantics). The guest retains
     `spore-build-copy-v2` and v3 only as older compatible inputs. V5 is
     accepted only for immutable build-input disks; local-context link policy
     remains rejected.
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

The guest sees the writable rootfs plus, when COPY steps execute, bounded
read-only context or immutable build-input disks (`spore_rootfs=1
spore_rootfs_rw=1`, with `spore_build_context=1` and/or
`spore_build_inputs=<count>`). The initrd agent now provides the build control verbs
(`spore-rootfs-grow-v1`, `fsfreeze-v1`, `fsthaw-v1`, `spore-build-run-v1`,
`spore-build-run-v2`, `spore-build-run-v3`, `spore-build-run-v4`,
`spore-build-copy-v4`, `spore-build-copy-v5`); the target base must provide `/bin/sh` for shell-form
RUN and nothing for capacity preparation. Exec-form RUN instead requires only
its selected executable. The guest accepts the older
`spore-build-copy-v2` context-only and v3 requests for compatibility. A missing RUN
shell fails closed through the step's captured output.

## COPY Semantics

`COPY` goes **through the guest**, inside the same persistent build-VM
session as `RUN`, rather than host-side ext4 surgery:

1. On the host, resolve sources against the context with the same walker used
   by hashing. It rejects absolute and `..` paths, opens every parent component
   fd-relatively without following symlinks, preserves a final symlink as COPY
   data, and applies `.dockerignore`. Executor misses stream each matched file
   once into a private sparse spool while hashing those same bytes; modes and
   symlink targets are captured by value. The immutable captured entries are
   both the cache input digest and the context-disk source. A supported heredoc
   skips context traversal: its bounded resolved bytes, fixed mode, and
   delimiter-derived name directly form the same typed regular-file entry.
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
4. Send fixed-shape `spore-build-copy-v4` ordinary requests or strict v5
   cross-stage link requests. Each request names
   the context or immutable build-input disk and bounded input index, source
   subtree, destination, source kind, `dest_is_dir`, entry count, and optional
   ADD mtime. The guest
   enforces disk, index, path, and entry-count bounds, then recursively copies
   from the selected read-only mount. An immutable build-input source operand
   follows its final symlink through the confined source resolver; symlinks
   encountered below a copied directory remain entries. Destination paths are resolved
   relative to an fd for `/mnt/rootfs` with `openat2(RESOLVE_IN_ROOT |
   RESOLVE_NO_MAGICLINKS)`, falling back on kernels without `openat2` to a
   confined manual component walk that keeps symlink targets rooted in the
   rootfs. Final-component symlinks are followed under the same confined
   resolution for ordinary COPY, so file entries write through them, directory entries merge
   through symlinked directories, and dangling file symlink targets are created
   inside the rootfs. It applies entries with root ownership, parent creation,
   directory merge, file overwrite, and symlink preservation. Link policy
   creates a scratch-like destination tree: implicit directories are real
   root-owned `0755` entries, lower symlinks are not followed, conflicting lower
   types are removed within the traversal bound, and lower contents survive
   only for directory-on-directory merges.
5. Checkpoint exactly as RUN does (freeze, dirty-only sealing plus full-index
   emission, complete stamp, step record, thaw).

Corollary: COPY and remote URL ADD do not require `tar` in the base image or add a tar
or custom entry-stream parser to the initrd agent, and keeps guest memory usage
bounded by per-entry copy buffers rather than total input size. COPY flags
`--chown`, `--chmod`, `--parents`, and local-context `--link`, plus local, Git,
extracting, and ADD flags other than numeric `--chmod`, remain unsupported and
fail closed.

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
- Cross-stage `COPY --link=true` ignores lower destination symlinks and type
  when constructing its upper result, then merges that result above the parent;
  `--link=false` uses ordinary COPY semantics.
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

Effort ranges are planning estimates for one engineer familiar with the code,
including tests, fuzzing, docs, and real-hardware smoke. Tracks overlap and are
not additive commitments.

### C0 — Baseline closure and conformance harness

Implementation note (2026-07-09): the first M1 implementation slice adds the
`spore build` CLI, Dockerfile subset parser, `.dockerignore`/COPY context
hashing, local step-cache read/write helpers, fully cached build resolution, and
indexed local image publication/run resolution. M2 starts at executor-owned
cache misses; it should write the same `sporevm-build-step-v1` records after
each dirty-only sealing/full-index checkpoint.

**Implementation status:** complete.

The implemented baseline now:

- records the Docker-vs-Spore filesystem/config oracle for the existing
  single-stage workload;
- proves exact trailing-COPY invalidation and warm cache behavior;
- preserves Docker-visible `/tmp` and `/run` across cached-prefix restarts;
- keeps resolver injection transient across checkpoints, including bases whose
  `/etc/resolv.conf` has a dangling systemd-style target;
- moves rootfs grow/resize support out of the selected base so a shell-less
  `scratch` stage can execute COPY and metadata operations;
- adds build memory, vCPU, timeout, and `nofile` controls sufficient for large
  dependency and frontend builds, and makes command/environment/workdir/timeout
  bounds explicit product limits rather than hidden protocol surprises;
- normalizes ordinary `./` COPY sources, replaces the single-star matcher with
  a bounded Docker-compatible glob matcher, and adds `.dockerignore`
  differential fixtures;
- adds step-record pruning and defines the operation-specific cache-schema
  migration used by later compatibility slices;
- provides a table-driven conformance harness with strictly validated fixture
  manifests that runs the same small Dockerfile through BuildKit and Spore,
  then compares normalized filesystem, config, success/failure, and selected
  cache behavior.

The harness contains small public fixtures: metadata-only, shell RUN plus a
negative exec-form fixture, context COPY, workdir, symlinks, empty directories,
and cache invalidation. It is runnable locally and on real Linux ARM64 hardware.
The Buildkite pipeline has a bounded Linux ARM64 conformance step that remains
the regression gate for this baseline.

**Local proof (2026-07-11):** `mise run build`, `mise run test`,
`zig build spore-build-run-smoke`, and
`scripts/spore-build-conformance.py --spore-bin zig-out/bin/spore` pass. The
differential harness reports 8/8 cases against BuildKit v0.30.0 on
`linux/arm64`; the Spore side ran natively on HVF. The COPY fixture forces a
`0775` source-root directory and verifies Docker's `0755` mode for a newly
created destination container while preserving an existing destination's mode.

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

**Stop/go gate:** passed on 2026-07-11. C1 may begin. Any future unexplained
filesystem or metadata difference in the baseline oracle is a stop.

### C1 — Ordinary multi-stage Dockerfiles — implemented 2026-07-11

**Estimate:** 6–10 weeks, delivered as several reviewable changes.

1. **Done:** replace the flat frontend output with source-spanned stages and typed
   operations. Parse standard directives, `FROM ... AS`, `FROM --platform`,
   global ARGs, automatic platform ARGs, stage names, and `--target`.
2. **Done:** build and validate the selected target dependency graph. Execute stages
   sequentially in topological order and cache immutable `StageArtifact`s.
3. **Done:** support `scratch`, public registry bases, previous-stage bases, and complete
   OCI config inheritance.
4. **Done:** implement literal-path `COPY --from` from stages, named build contexts, and local/OCI
   images through confined read-only stage disks.
5. **Done:** preserve and publish `Entrypoint` and `Cmd`, including exec-form
   `ENTRYPOINT` needed by shell-less runtime stages.
6. **Done:** publish the selected target only; unreferenced invalid stages must still be
   syntactically valid but need not fetch or execute external bases.

Post-merge compatibility correction (2026-07-13): executor-backed `RUN`
steps execute as root and receive `HOME=/root` when the inherited/base
environment and effective Dockerfile/build arguments leave `HOME` absent or
empty. This matches BuildKit's root-process environment without rewriting the
published OCI config: `ENV HOME=` stays published as empty, while explicit
non-empty values remain authoritative. ENV and ARG follow instruction order for
build execution without publishing ARG. The effective root-process value
participates in the RUN environment digest, so pre-correction empty-HOME records
cannot hit; HOME normalization alone does not change COPY or WORKDIR cache
identities. Stages also receive BuildKit's conventional Linux
`PATH` when it is absent; unlike HOME, PATH is stage environment state and part
of the published OCI environment, including for `FROM scratch`. An explicit
PATH remains authoritative in the published config; a later ARG follows
BuildKit's ordinary instruction-order semantics for effective build state
without becoming published ENV. In particular, ARG followed by ENV leaves ENV
effective, while ENV followed by ARG changes later build execution but retains
the published ENV value. PATH participates in every environment-bound
Dockerfile operation key, so older records created without it miss safely. This
does not add `USER` execution semantics. Imported duplicate environment keys
remain ordered in published `Config.Env`, while the current stage carries a
separate last-value-wins effective view. A later Dockerfile `ENV` updates both
views according to their respective Docker semantics before subsequent
expansion, execution, and cache hashing. A new `FROM` reconstructs its
effective view from the preceding stage's published `Config.Env`, matching
BuildKit when that raw list still contains duplicates. RUN rejects effective
entries that are bare empty strings, have an empty `=value` name, or contain an
embedded NUL before cache lookup. Nonempty entries without `=` remain unchanged
in raw OCI publication but become empty-valued `NAME=` entries in the effective
environment to match the pinned BuildKit/runc path. This also makes a bare
inherited `PATH` authoritative as an empty PATH instead of adding the
conventional default.

Structural follow-ups are explicit gates before C2 widens the instruction
surface:

- **Done:** extract the cache-prefix walk and executor-suffix lowering from
  `src/build.zig` behind one typed RUN/COPY/ADD/WORKDIR transition.
- **Done:** decode current builder records through one canonical adapter shared by
  cache-hit and GC validation.
- **Done:** move the build COPY filesystem engine out of the PID1 protocol
  dispatcher into `guest/minimal-initrd/build_copy.c`; the PID1 agent retains
  bounded request parsing, source-disk readiness, dispatch, and SPIO replies.
- **Done:** split the conformance schema and comparison code from its CLI
  lifecycle.

All four structural gates are complete, so C2 may widen the supported
instruction surface without duplicating these representations. Further
operation kinds and COPY policy should build on the extracted seams.

Representative acceptance fixture:

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/app ./cmd/app

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
emission → completeness stamp → thaw → `PREPARE` record occurs before
Dockerfile step zero, and the same VM continues on a miss. Deferring the
authoritative record until thaw succeeds prevents an un-restorable VM
transition from becoming a cache hit. A hit supplies the normal Dockerfile
parent even under `--no-cache`. The hidden growth override was removed;
above-cap images remain byte-exact and are never rounded or doubled.

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
and originally sent bounded `spore-build-copy-v2` context-only control
messages. The current executor emits strict `spore-build-copy-v4` for ordinary
COPY/ADD and strict v5 for cross-stage link policy. Both bind the selected
context or immutable build-input disk, bounded input index, and optional ADD
mtime; v5 also requires the exact `link` destination policy and rejects context
disks. The guest retains v2 and v3 for older compatible input, validates current
v4 and v5 objects as exact newline-terminated shapes, mounts the selected disk
read-only, and confines all destination apply-path resolution to
`/mnt/rootfs`. Ordinary COPY preserves Docker-style rootfs-internal and
final-component symlink traversal. Link policy instead constructs real
destination directories without following lower symlinks, merges
directory-on-directory results, and removes a conflicting lower subtree within
the shared 65,536-entry bound before applying an upper file, directory, or
symlink.
COPY checkpoints use the same freeze → snapshot → complete stamp → step
record → thaw ordering as RUN; if any COPY request in a step fails, the build
fails before snapshot promotion for that step. Session start uses the
prepared parent produced by the v9 policy above; COPY keys never carry a grow
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

Performance follow-up (2026-07-14): profiling the current 64 MiB
`buildkite-sporevm` context against its 3 GiB OCI base found one 8.8 MiB layer
spending 13.28s replacing 1,538 existing regular files. Each replacement
scanned all 211,136 merged entries both for subtree removal and file-source
liveness. Non-directory replacement now removes the exact path, while
per-inode link counts preserve hardlink source lifetime; the layer fell to
27ms and total layer merge fell from 15.31s to 1.83s with the same final
rootfs identity. `SPOREVM_ROOTFS_BUILD_PROFILE=1` reports per-layer merge
timing, and executor diagnostics separate guest instruction, snapshot,
checkpoint-control, and remaining session time. An empty isolated cache must
still emit and seal the complete ext4/CAS artifact before publication, so that
first-use write remains distinct from BuildKit's already-unpacked local base
snapshot.

**Stop/go gate:** passed on 2026-07-13 at exact head `79ffbb2`. Buildkite
#1317 passed the exact Linux and macOS unit graphs plus Linux BuildKit
conformance. The complete local graph passed all 18 build steps with
1,742/1,755 tests passing and 13 skipped. Native HVF and KVM each passed all
11 build-run smoke sections, publication, capacity save/restore/pack/commit,
and block- plus inode-ENOSPC coverage; KVM also passed BuildKit conformance.
The native harness requires an absolute work root, so failed operator
invocations with a relative root are not product evidence.

The five-sample paired default-path gate remained stable at one PREPARE step,
one child, and one producer per sample, and every acceptance threshold passed:

| Backend | Profile | Cold median | Warm median | Incremental median |
| --- | --- | ---: | ---: | ---: |
| HVF | compact | 927.249 ms | 153.553 ms | 825.444 ms |
| HVF | pregrown | 926.491 ms | 198.975 ms | 977.930 ms |
| KVM | compact | 703.670 ms | 235.334 ms | 684.439 ms |
| KVM | pregrown | 808.544 ms | 304.584 ms | 752.371 ms |

The public evidence ledger identifies the HVF raw and summary artifacts by
SHA-256 prefixes `a16da275` and `aca67a54`, and the KVM raw and summary
artifacts by prefixes `b1156452` and `5536d36b`. The four structural
extractions above are complete, so C2 instruction and COPY-policy widening may
proceed through those seams. The C1 implementation reuses bounded instances of
the existing virtio-blk device and changes neither the frozen device types nor
the spore manifest format.

### C2 — Stable frontend and filesystem breadth

**Estimate:** 5–9 weeks.

Ceiling proven: cached full build (parse + stat-only context hash + lookups +
ref refresh) ≤2s warm-stat; uncached COPY ≈ context-disk emit/reuse +
guest disk-to-disk apply plus one freeze/dirty-only sealing and full-index checkpoint, with boot
amortized per build.

- **Done:** bounded exec-form RUN with exact Unicode-preserving argv, effective
  last-value-wins ENV/ARG, PATH lookup, strict newline framing, cache
  invalidation, and Docker/BuildKit differential coverage;

The merged exec-form RUN work has an independent manual SHIP verdict. Land
small general PRs in the order the unchanged Buildkite oracle demonstrates:

1. **Done — landed in PR #498:** builder-owned expansion and
   automatic platform arguments. Expansion-capable operands retain quote and
   escape provenance through parsing and resolve from one instruction-start
   snapshot. The shared resolver implements unset-to-empty plus stable `:-`,
   `-`, `:+`, and `+` operators; automatic BUILD/TARGET values derive from the
   selected platform and accept normal build-arg overrides. FROM, ARG defaults,
   ENV, COPY, and WORKDIR use that resolver, while exec-form RUN remains
   literal. A new environment-state digest identity prevents older
   quote-stripping COPY/WORKDIR records from aliasing the new semantics. The
   Dockerfile parser and dedicated resolver are fuzzed, and the pinned
   BuildKit v0.30.0 HVF differential graph passed all 30 cases, including
   ordering, inherited ENV/ARG, quoting, unset/set-empty operators, automatic
   platform values, warm hits, a resolved COPY-destination miss, malformed
   input, and a deliberately unsupported unstable modifier. No remote input is
   accepted by this slice.
2. **Done — landed in PR #501:** oracle-prioritized public HTTPS ADD. The
   separate C4 mutable-URL slice accepts
   the exact general form required at line 42: expanded public HTTPS source,
   expanded destination, opaque bytes, initial fixed mode `0600`, and always-refetch
   content-addressed reuse. The parser happens to encounter C4 before the
   remaining C2 breadth; that changes delivery order, not ownership. Rerun the
   unchanged target after landing to select the next slice. The rerun reached
   cross-stage `COPY --link` at line 72.
3. **Done:** result-correct cross-stage `COPY --link`. The accepted true policy
   extends the typed COPY instruction, transition, cache record, and strict
   v5 guest request. The guest builds the destination result without following
   lower symlinks, replaces file/directory conflicts, merges matching
   directories, and bounds removal by the existing COPY traversal envelope.
   Source-stage indexes and resolved destination/environment inputs remain
   cache identity, while the current parent remains a conservative dependency.
   This slice claims no parent-independent layer rebasing and leaves
   local-context `--link`, `--chmod`, `--parents`, and heredocs rejected.
4. **Done in this slice:** numeric `--chmod` for the existing public HTTPS
   single-file ADD path. The flag expands from the instruction-start snapshot,
   accepts only octal `0` through `07777`, binds the resolved mode in ADD input
   identity, and reuses the context-disk plus strict COPY v4 guest apply path.
   Mode changes miss, unchanged refetches with the same bytes and mode hit, and
   mode remains independent from the validated remote mtime. Symbolic modes,
   COPY chmod, local ADD, extraction, and other ADD flags remain rejected.
5. **Done — landed in PR #508:** single-source COPY heredoc. Exact merged main
   `6e679896d5b79f6bab2131ff7f8573c79537e66c`, tree `23ead6e7`, passed
   Buildkite #1399 and independent packaged HVF/KVM acceptance. The slice
   accepts one unquoted, non-chomping inline source with no flags, preserves
   the final newline and quote bytes, expands from the instruction-start
   snapshot, and lowers one root-owned `0644` file through the existing typed
   COPY and guest apply seams. The unchanged `fb742fd5` oracle then parsed both
   COPY heredocs and stopped parser-only at the cache-mounted RUN heredoc whose
   instruction begins on line 130, with zero fetch, VM, runtime, rootfs, or
   cache mutation.
6. **Done — landed in PR #509:** single shell RUN heredoc. BuildKit v0.30.0 source and a pinned
   Buildx v0.33.0 differential show that `RUN <<NAME` without a shebang lowers
   the exact body to the ordinary shell RUN path; the frontend does not substitute
   the body, so ARG/ENV, quotes, escapes, unset variables, and parameter
   operators retain ordinary shell semantics. The accepted slice is exactly
   one unquoted, non-chomping marker as the complete command after zero or more
   already-supported default cache mounts. It requires a non-empty body without
   NUL or a leading shebang, preserves the final newline, and reuses the typed
   RUN transition plus existing v1/v3 shell requests, timeout, sandbox,
   selected cache-mount plan, and cleanup. Exact canonical body text,
   effective ARG/ENV state, workdir, network, resources, ordered normalized
   mount identity, parent rootfs, and executor identity remain cache inputs.
   Shell-prefix, quoted, chomping, multiple, empty, shebang/direct-exec, and
   exec-form heredocs fail during the full-file parse/preflight pass. This is
   the narrow general form required by frozen line 130; it does not add a guest
   protocol or alter C3 storage or sandbox contracts. Exact merged main
   `b8702decef5a1f73f93854af4f070c74d4375ed9`, tree `6902c634`, passed
   Buildkite #1401 and independent packaged HVF/KVM acceptance. The unchanged
   oracle then stopped parser-only at line 237 on `RUN --mount=type=ssh`.
7. **Done — landed in PR #510:** optional-absent SSH declaration compatibility. Accept only one
   exact default `type=ssh` declaration with no caller input. Pinned BuildKit
   v0.30.0 injects `SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` when the effective
   RUN environment lacks that key but creates no socket or path when the mount
   is optional and absent. Match that inert value and precedence, bind the
   resolved environment plus typed `ssh_declared_absent` state into cache
   identity, and reject every option, duplicate, required/custom, host-input,
   secret, and forwarding form before execution. This slice adds no guest
   protocol or credential authority; the next unchanged-oracle failure should
   be the first context bind mount later in the same instruction. Exact merged
   main `13b0e5fb68f6bc567935190e352db67bf1f94611`, tree `a5095c35`, passed
   Buildkite #1403 plus independent packaged HVF/KVM acceptance. The unchanged
   oracle advanced through SSH and stopped on the first context `type=bind`
   declaration in the same line-237 instruction with zero state mutation.
8. **Active — immutable context regular-file binds.** Accept only default
   read-only `type=bind,source=<file>,target=<path>` from the build context,
   composed with the landed absent SSH declaration and default cache mounts on
   ordinary shell-form RUN. Exec-form and heredoc combinations remain
   fail-closed in this slice.
   Normalize expanded literal sources and targets at instruction start, resolve
   `.dockerignore` before execution, capture one regular file per bind into the
   existing immutable context disk, and bind ordered path/mode/content inputs
   into RUN identity. Preserve the same captured source mtime only in a
   context-disk v2 transport identity; omit it from semantic RUN
   identity to match BuildKit's mtime-only hit behavior. The operation-owned sandbox exposes only selected files;
   reverse-order unmount and inode-owned target cleanup precede checkpoint.
   Writable/custom, directory/symlink/special, stage/image/named-context, and
   overlapping forms stay fail-closed. Root and trailing-slash targets plus
   targets at or beneath `/proc`, `/dev`, `/sys`, `/run/sporevm`,
   `/run/buildkit`, and `/etc/resolv.conf` are rejected during full-file
   planning. Protected-path overlap is symmetric, so ancestors that would hide
   a protected path and descendants that would alter one both fail closed.
   The unchanged `fb742fd5` Buildkite oracle on this candidate parses through
   all three line-237 context binds and stops parser-only at line 259 on
   `type=cache,id=frontend-yarn,sharing=locked,target=/usr/local/share/.cache/yarn`.
   It exits 2 with no fetch, VM, runtime, rootfs, kernel, or cache mutation, so
   explicit cache ID plus `sharing=locked` is the next grounded C3 boundary and
   remains outside this slice.
9. **Remaining Buildkite-reachable frontend and filesystem behavior.** Add
   `COPY --parents` and `COPY --chmod` only when the next unchanged-oracle run
   reaches them. Split these into separate PRs whenever their parser,
   filesystem result, cache identity, or failure-publication protocols differ.
10. **Evidence-gated matching.** Close glob and `.dockerignore` gaps only when
   a later unchanged-oracle run produces a concrete mismatch or unsupported
   span.
11. **Deferred breadth.** Add `RUN --security=sandbox`, `COPY --chown` and
   `--exclude`, `SHELL`, `USER`, `LABEL`, `EXPOSE`, `STOPSIGNAL`,
   `HEALTHCHECK`, `VOLUME`, and other metadata only when the unchanged workload
   or the representative common-template corpus demonstrates demand.

C3 cache/bind mounts and C4 ADD remain outside C2 PRs even when the oracle
reaches them. C2 changes should preserve typed plan, input, and cleanup seams
that those later phases can extend without accepting their semantics early.

Acceptance corpus includes representative Go, Rust, Node, and Ruby multi-stage
images plus focused ownership, symlink, JSON, heredoc, and metadata fixtures.
After every landed slice, rerun the exact pinned Buildkite target unchanged and
record its next first failure before selecting another slice.

**Done when:** the C2 capabilities required by the unchanged Buildkite target
and common application templates build without syntax rewrites and normalized
result/config differential tests pass. A subsequent C3 or C4 blocker does not
make the preceding C2 slice incomplete.

**Stop/go gate:** a feature with unresolved result semantics remains rejected.
Do not accept it merely because parsing succeeds.

### C3 — Generic mounted RUN

**Estimate:** 6–10 weeks.

1. **Landed foundation:** every ordinary shell- and exec-form RUN gets a
   private PID/mount/cgroup/IPC/UTS view, scoped procfs, minimal `/dev`,
   device-deny policy, bounded capabilities, and transactional teardown. Exact
   merged-main CI and packaged HVF/KVM acceptance prove `/proc/1/root`, proc
   sysctls, AF_VSOCK, console and auxiliary virtio devices, device-node aliases,
   namespace joins, and mount attempts cannot escape the view while ordinary
   stdio, networking, environment, workdir, root-user, exit, and rootfs behavior
   remain compatible with pinned BuildKit.

The landed first mounted-RUN slice implements only multiple cache mounts with
`type=cache`, `target`, and omitted `id`/`sharing`. It uses a bounded 4 GiB
sparse aggregate ext4 disk outside rootfs CAS plus a single exclusive store
lock, conservatively serializing BuildKit's default shared-writer mode. The
cleaned expanded target is the default ID and the ordered resolved target,
default ID, derived storage key, and `shared` policy enter builder-v9 RUN cache
identity; mutable cache contents deliberately do not. A strict
`spore-build-run-v3` request carries at most eight canonical absolute targets
and lowercase 256-bit storage keys. Reverse-order unmount, `syncfs`, clean disk
unmount, and removal of builder-created target directories complete before the
existing freeze/checkpoint protocol. The transient disk reuses virtio-blk but
does not enter any manifest or frozen device contract; invalid or unclean
host-local disks are discarded rather than trusted. A context disk plus two
stage-input disks already fills the remaining frozen virtio slots, so combining
that envelope with a cache-mounted RUN fails during selected-plan preflight.
The aggregate is not yet included in `spore rootfs df`, prune, or GC accounting.
The landed operation sandbox is the selected-cache security boundary: cache
binds enter only its private mount view, while its scoped procfs, minimal `/dev`,
device policy, capability set, and syscall filter keep sibling cache directories,
the aggregate block device, console, vsock, and initrd namespace unreachable.
The unchanged frozen Buildkite target at commit `fb742fd5` and Dockerfile
SHA-256 `36867efe6eef1e96da5115aa91df0d087be61763c0097846a971d8709e659a2b`
parsed through its three line-82 default cache mounts after merged-main
acceptance at `8655d5b0` and next failed during whole-file parsing at line 121
on `COPY <<EOF`. No fetch, VM boot, or cache/runtime mutation occurred, so the
single-source COPY heredoc slice became the next grounded boundary. That slice
landed unchanged in PR #508 at exact main `6e679896`, passed Buildkite #1399
and packaged HVF/KVM acceptance, and moved the same zero-mutation oracle to the
line-130 cache-mounted `RUN <<EOF`. That heredoc slice landed in PR #509 at
exact main `b8702dec`, after which the unchanged zero-mutation oracle reached
line 237 and stopped on the leading default `type=ssh` declaration. Pinned
BuildKit evidence and an explicit product/security decision selected the
optional-absent compatibility slice above; actual forwarding remains outside
C3.
2. Expand context binds beyond regular files only when a grounded workload
   requires it, then implement stage bind mounts and tmpfs mounts as separate
   slices.
3. Add per-RUN network selection and key it independently from global default.
4. Generalize the landed default-ID store with explicit-ID ownership,
   per-ID concurrency, accounting, prune, and GC. `sharing=locked` maps directly
   to exclusive locking; default/shared writers may be serialized more
   aggressively; unsupported `private` behavior fails closed.

Every mounted operation verifies unmount and helper cleanup before snapshot.
Cache volumes have separate reachability and GC from rootfs step records.

**Done when:** apt, compiler, Bundler, and Yarn cache-mount fixtures produce the
same final image as BuildKit; cache contents survive intended rebuilds but are
absent from every stage artifact; concurrent builds cannot corrupt a cache even
when Spore serializes work that BuildKit could run concurrently.

**Stop/go gate:** if cache mounts require broad multi-disk manifest or runtime
format changes, stop and compare a build-local aggregate cache disk against the
larger generic design. Do not expand spore manifests solely for build caches.

### C4 — Safe ADD inputs

**Estimate:** 3–5 weeks.

- **Implemented in the narrow mutable-URL slice:** a bounded host-fetched
  public HTTPS single-file ADD for the exact
  mutable-URL form proven by the oracle, while keeping the implementation
  general. Expand URL and destination through the C2 engine, preserve remote
  gzip bytes without local-tar extraction, stage bytes durably before applying
  them through the shared COPY destination/ownership/mode machinery, and fail
  closed on unsupported schemes, redirect-policy violations, status codes,
  size, time, count, aggregate-body, or destination behavior. A build accepts
  at most 64 remote ADD instructions, 1 GiB of combined response bodies, and
  ten minutes of combined host-fetch time or the smaller build timeout;
- use Zig's standard URI/HTTP primitives and the existing neutral public-target,
  DNS-rebinding, and resolved-address TLS helpers in `host_fetch_policy.zig`.
  The ADD owner retains its response bounds, redirect semantics, staging, and
  content identity rather than coupling them to registry-specific fetch rules;
- key every persistent semantic input, including the resolved URL and
  destination, platform/ARG values, actual content digest, safe response
  `Content-Disposition` filename or URL-path fallback,
  validated optional `Last-Modified` timestamp, mode/ownership policy, parent
  state, and executor/parser producer identities.
  The approved conservative contract refetches every build before lookup. Each
  redirect is policy-validated, while its potentially ephemeral signed URL is
  not stable semantic identity; unchanged requested URL plus unchanged bytes
  may hit, and changed bytes must miss;
- add `ADD --checksum` as a separate integrity-pinned form rather than
  pretending the observed mutable URL is immutable;
- local tar ADD through the existing bounded extraction model;
- `--chmod`, ownership, excludes, link behavior, and destination rules shared
  with COPY where Docker defines the same contract. Numeric remote-file
  `--chmod` is implemented through the existing context-disk/COPY v4 path;
  symbolic and COPY modes remain separate work;
- explicit rejection for remote Git sources, Git build contexts,
  `--keep-git-dir`, and remote `--unpack`;
- update `SECURITY.md`, compatibility notes, and release notes in the owning
  slice, and extend the Dockerfile fuzz target in the same change for every new
  attacker-influenced ADD operand or flag grammar.

**This slice is done when:** pinned remote URL ADD fixtures match BuildKit result
semantics under expansion, redirects, errors, changed remote bytes, destination
rules, ownership, and cold/warm/rebuild cache behavior, while unsupported
transports and later unsupported instructions fail before ADD network access.
Checksum, local ADD, ownership flags, merge behavior, and extraction retain
their own later acceptance work. The public differential fixture changes both
the requested URL and bytes; same-URL changed-content invalidation is covered by
the typed content-digest identity unit test rather than claimed as differential
proof.

**Stop/go gate:** do not turn `ADD` into a source-control client or general
remote archive service. A feature requiring Git credentials, submodules, SSH,
or mutable repository semantics remains rejected.

### C5 — Buildkite `ci` compatibility recipe

**Estimate:** integration and discovered gaps after the required C2–C4 slices.

Use the exact unmodified Buildkite Dockerfile at revision
`fb742fd5291244e2a1b9c174112f23e2a1581217` as the advanced acceptance
workload throughout delivery, not only after C4. Its target closure exercises:

- standard syntax directive and automatic platform ARGs;
- public remote bases and URL ADD;
- target-pruned multi-stage inheritance;
- cross-stage COPY and `--link`;
- cache and bind RUN mounts;
- RUN/COPY heredocs;
- `--parents`, chmod, and multi-star globs;
- large Bundler/Yarn/frontend/Rails steps and high `nofile` requirements.

Validation compares the selected `ci` target's normalized filesystem and OCI
config against BuildKit, runs representative Ruby/RSpec, Node/Yarn, and bktec
probes, and verifies code-only changes reuse stable dependency stages. The
upstream stable-runtime/committed-Docker-store path may continue in parallel as
an operational benchmark, but no Buildkite-specific instruction or cache type
enters SporeVM.

**Done when:** `spore build --target ci --tag local/buildkite-ci
/path/to/fb742fd` builds the unmodified pinned target on Linux ARM64 with no
BuildKit prerequisite, the result passes `/bin/true` plus Ruby, Bundler, and
RSpec probes, and cold, warm, incremental, source, lockfile, build-arg, and
base-change evidence proves sound cache behavior. The optional-absent SSH
declaration above is the complete credential-free compatibility boundary; any
workload that needs a real agent remains unsupported rather than silently
forwarding credentials.

### C6 — Evidence-gated long tail

No blanket parity milestone follows C5. Add features from real corpus failures:

- registry Docker config, basic auth, and credential helpers;
- ONBUILD only if representative image bases demonstrate material demand;
- richer healthcheck and metadata edge cases;
- standard frontend version updates.

OCI layer output, registry publishing, cache import/export, remote shared cache,
custom frontend images, labs features, secret or credential-bearing SSH mounts,
remote Git inputs, privileged execution, and host integration stay outside this
roadmap. A future named credential broker requires its own product and security
plan.

## Verification

### Frontend and planner

- Parser: unit tests per instruction, substitution, continuations, comments;
  exact fail-closed error text for each unsupported feature; fuzz target.
- Step keys: golden tests that keys are stable across runs and change exactly
  when the spec says (each invalidation rule in the Cache Model section gets a
  test).
- Step cache: v9 PREPARE keys vary with parent, exact target, and producer;
  Dockerfile keys use the prepared child and contain no growth target; records
  survive process restart; missing artifact ⇒ miss; corrupted record ⇒ miss;
  missing complete stamp ⇒ miss without repair; atomic write leaves no partial
  record after simulated failure between snapshot publication and record write;
  v8, v7, and v6 records remain GC roots but are cache misses.
- Executor: exit-code propagation, env/workdir application, network
  on/off, idempotent 16 GiB policy, already-large preservation, clean-zero
  sparse growth, direct resize response validation, same-VM PREPARE checkpoint,
  `--no-cache` PREPARE reuse, and failure cleanup before any Dockerfile step or
  destination-ref publication.
- RUN sandbox: ordinary shell and exec differential fixtures plus adversarial
  HVF and KVM coverage for scoped procfs, denied proc-sysctl mutation,
  denied AF_VSOCK, absent default
  console and auxiliary-disk nodes, denied raw access through attacker-created
  aliases, mount and namespace denial, minimal devices, exact exit/signal
  propagation, timeout/setup failure, descendant cleanup, and a clean following
  RUN/checkpoint.
- COPY matrix listed above, plus context-escape rejection tests.
- Large COPY: generated sparse fixture with aggregate payload above guest RAM
  succeeds through context-disk apply and records emitted/reused diagnostics.
- End-to-end: small fixture base (tiny OCI layout already used by import
  tests) through FROM+RUN+COPY+CMD, then `spore run` smoke; the real
  `buildkite-sporevm` path as the M3 hardware smoke.
- Equivalence: scripted file-tree diff (path, type, mode, uid/gid, size,
  symlink target) between spore-built and buildx-built rootfs.
- Prioritization oracle: after every relevant landing, run the exact unmodified
  Buildkite `ci` target at `fb742fd` in read-only task-owned scratch and stop at
  its first grounded unsupported behavior. Map the failure to C2, C3, C4, or
  the explicit SSH decision before selecting more work.
- The first pinned run on `606a7a24` stops during full-file parsing at line 42,
  before network or execution, on the mutable HTTPS `ADD` whose URL and
  destination contain ARG/platform expansion. Preserve that result as the
  baseline until the separate C2 expansion and C4 URL-ADD slices land.

### Filesystem and configuration

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

### Cache

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

- Every build RUN uses a dedicated operation-owned sandbox before C3 accepts
  any mount syntax. Rejected: retaining the agent's mount/PID namespace with a
  chroot and cgroup alone, because procfs exposes the init namespace and rootfs
  devtmpfs exposes every virtio block device. The selected view uses private
  PID/mount/cgroup/IPC/UTS namespaces, descriptor-clean rootfs confinement,
  scoped procfs, minimal `/dev`, a cgroup device policy, a narrow AF_VSOCK and
  io_uring seccomp denial, and the pinned BuildKit capability
  set; VM-level networking remains unchanged to preserve the current RUN
  network contract.
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
- `/bin/sh -c` for shell-form RUN, not `-lc`; exec form runs its exact argv
  without a shell (Docker parity).
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
  cache v9, keyed by parent index, exact target, and exact kernel/initrd plus
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
- An `ARG` declaration without a default records an absent value in the
  instruction-start snapshot. Ordinary builder-owned substitution expands an
  unset value to empty, while supported parameter operators may distinguish
  unset from set-empty; the resolved operand and the snapshot inputs that
  determine it participate in cache identity.
- The unchanged Buildkite `ci` target at `fb742fd` is the prioritization oracle
  for remaining compatibility work. It selects ordering by evidence but does
  not define Buildkite-specific product behavior or permit C3 mounts, C4 ADD,
  or credential forwarding to enter C2.
- The first post-merge oracle failure is the mutable public HTTPS `ADD` at line
  42. Delivery therefore advances the independent C2 expansion/platform-value
  foundation and then the smallest sound C4 URL-ADD slice before unrelated C2
  metadata breadth; the two capabilities remain separately reviewed and owned.
- Mutable public HTTPS ADD uses an always-refetch, content-addressed contract.
  The host re-resolves and GETs each accepted URL on every build, stages and
  syncs bounded bytes, hashes them before cache lookup, and may reuse only when
  the resolved operands, content digest, and validated optional Last-Modified
  result match. A valid HTTP-date becomes the destination mtime through the
  shared confined apply path, while an absent or malformed date uses the Unix
  epoch. This is intentionally more conservative than
  validator-based reuse and grants no credential authority. The builder sends
  no `Authorization` header and does not consult host credential stores; URI
  userinfo is rejected,
  while requested query strings and server-provided HTTPS redirect targets
  remain ordinary URL data. A build accepts at most 64 remote ADD instructions,
  1 GiB of combined response bodies, and ten minutes of combined host-fetch
  time or the smaller build timeout.
- One exact default `RUN --mount=type=ssh` declaration is accepted only as
  optional-absent compatibility when no SSH input exists. Pinned BuildKit
  v0.30.0 injects an inert `SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` value when
  the effective RUN environment does not already define the key, while omitting
  the mount itself. Spore matches that observable value and precedence, records
  `ssh_declared_absent` plus the resolved environment in cache identity, and
  creates no socket, path, transport, broker, CLI input, or durable state.
  Credential-bearing and customized forms remain rejected.

## Deferred Decisions And Triggers

- Capacity-at-import remains an optional optimization only if measurements show
  value. PREPARE is the product contract because it also covers existing local,
  committed, cached, and source-less images without multiplying formats or
  user intent.
- Any future automatic capacity above 16 GiB needs a compact index format or a
  lower proven dense-index ceiling; the current 64 MiB index limit is a hard
  format constraint, not a reason to add a user knob.
- Actual SSH forwarding remains outside this roadmap. Revisit it only through a
  separate named-credential-broker product and security plan; the accepted
  optional-absent declaration grants no forwarding authority and does not make
  raw SSH mounts an incremental extension.

## Key Learnings From Pressure-Testing

- Cache teardown needs path ownership, not a count of created directories.
  RUN may add legitimate sibling state under a setup-created parent or replace
  the target path entirely. Recording target and created-component identities
  lets teardown preserve a nonempty ancestor while failing closed on
  replacement; poisoning the session while PID 1 drains exit 125 avoids losing
  the vsock failure frame before the host can stop the VM.
- A chroot and cgroup bound process lifetime but did not bound filesystem
  authority: `/proc/1/root` reached the initrd namespace and rootfs devtmpfs
  named auxiliary virtio disks. Cache mounts would turn that latent authority
  into writable cross-operation state, so the operation-owned namespace and
  device boundary must land before any mounted RUN syntax.
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
- An unchanged real target is a better ordering oracle than a speculative
  compatibility checklist, but it must remain an oracle. Its C3, C4, or SSH
  failures route work to those explicit phases or decisions instead of
  broadening the current C2 PR.
- Parser order can expose a later milestone before earlier breadth is complete.
  Advancing the narrow owning slice preserves fail-closed parsing and keeps the
  cache and security contract coherent; combining C2 expansion with C4 network
  input merely to make one Dockerfile progress would erase those review
  boundaries.
