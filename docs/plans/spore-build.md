---
status: active
last_reviewed: 2026-07-23
spec_refs:
  - docs/spore-build.md
  - docs/filesystem.md
  - docs/rootfs.md
  - docs/benchmarks.md
  - docs/spore-format.md
  - SECURITY.md
  - src/build.zig
  - src/build/
  - src/build_cli.zig
  - test/build/conformance/
related_plans:
  - docs/plans/image-gateway.md
---

# Spore-Native Dockerfile Builder Compatibility Roadmap

## Summary

`spore build` is now a useful native Dockerfile builder. The frozen
`buildkite-sporevm` acceptance Dockerfile builds without source changes, the
result starts as a normal local Spore image, the named workflow reaches ready,
`bin/setup` completes with live output, and a real RSpec file passes. The
durable command and compatibility contract lives in
[Spore Build](../spore-build.md).

The remaining work is proof and operational closure rather than another broad
parser expansion. We still need a normalized Docker-versus-Spore filesystem and
OCI-config oracle over the real workload, an exact COPY invalidation proof,
repeatable wrapper-level cold/warm/incremental measurements, and a safe way to
retire obsolete build records without making reachable CAS storage collectable.

New Dockerfile features stay evidence-gated. A real public workload failure may
justify another narrow slice, but the roadmap does not end in blanket BuildKit
parity.

## Problem

The current fixture suite proves the supported subset instruction by
instruction, and the frozen Buildkite target proves that the pieces compose in
one large Dockerfile. Those are different from proving the complete selected
filesystem and image configuration match BuildKit, or that one real source edit
invalidates exactly the required suffix without reusing stale output.

The operational path also has work outside the core parser. A warm `spore build`
can be quick while a wrapper still copies hundreds of megabytes of context or
rebuilds inputs before invoking it. Benchmarks must separate wrapper setup,
builder planning, cache lookup, VM work, image publication, named readiness,
setup, and the downstream test command.

Finally, builder-v9 correctly retains complete v6, v7, and v8 records as
conservative GC roots. That is safe but grows without a retirement contract.
Removing old records is a reachability problem, not a file-age cleanup.

## Goals

- Prove the frozen real workload's normalized filesystem and OCI runtime config
  match the Docker/BuildKit result for every accepted feature it exercises.
- Prove real source changes invalidate the correct COPY-dependent suffix and
  cannot return stale output.
- Record repeatable cold, warm, and one-file incremental behavior across the
  complete downstream wrapper and named acceptance path.
- Define conservative step-record retirement that cannot delete a reachable
  rootfs index or chunk.
- Keep unsupported syntax fail-closed during full-file planning.
- Add compatibility only from concrete public corpus failures with matching
  differential, cache, security, and fuzz coverage.

## Non-Goals

- No blanket Dockerfile or BuildKit parity milestone.
- No Docker layer/history generation, OCI registry output, or BuildKit cache
  import/export.
- No cross-machine shared Spore build cache.
- No custom frontend images, labs syntax, frontend plugins, Windows builds, or
  foreign-architecture execution.
- No credential-bearing SSH, raw secret mounts, privileged RUN, Docker socket,
  host device, or arbitrary writable host-path access.
- No Buildkite-specific instruction, cache type, or product behavior.
- No performance claim based only on the inner `spore build` process when the
  wrapper remains the user-visible entry point.

## Current State

The landed foundation includes:

- full-file source-spanned parsing and reachable-stage planning before any
  fetch or execution;
- multi-stage `FROM`, target selection, local/registry/named OCI-layout bases,
  previous-stage inheritance, and final `CMD`/`ENTRYPOINT` publication;
- builder-owned ARG/ENV/platform expansion, parent-relative `WORKDIR`, shell
  and bounded exec-form RUN, and simple RUN/COPY heredocs;
- immutable context COPY, cross-stage COPY, cross-stage `COPY --link`, and
  context `COPY --parents`;
- bounded public HTTPS `ADD` with numeric `--chmod`;
- operation-owned RUN sandboxing;
- bounded cache mounts, immutable context-file bind mounts, and the exact
  optional-absent SSH declaration;
- automatic sparse 16 GiB capacity preparation through typed `PREPARE`, with
  no selected-image shell or e2fsprogs dependency;
- persistent build-VM execution, per-instruction freeze/snapshot/thaw,
  dirty-only chunk sealing, and atomic local-ref publication;
- cache-mount aggregate accounting plus lock-serialized prune and GC, with
  process-bound crash recovery, stale-temp scavenging, and separate
  allocated-byte reclamation; and
- Docker/BuildKit differential fixtures for the supported subset.

The frozen Buildkite acceptance target remains revision
`fb742fd5291244e2a1b9c174112f23e2a1581217`. On merged SporeVM main, the last
recorded acceptance run completed a forced cold build in 148.78 seconds, a warm
rebuild in 9.87 seconds, and a one-file incremental rebuild in 7.31 seconds.
The resulting named workflow reached ready, completed `bin/setup` with
untruncated output, and passed 11 examples in one real RSpec file. These are
useful point measurements, not the repeatable wrapper benchmark required below.

| Work | Status |
| --- | --- |
| Supported-subset parser, executor, cache, sandbox, and conformance foundation | Landed |
| Frozen real Dockerfile build and representative named RSpec acceptance | Landed |
| Normalized real-workload filesystem and OCI-config differential | Active |
| Exact real-workload COPY invalidation proof | Active |
| Wrapper integration and repeatable cold/warm/incremental measurements | Follow-up |
| Obsolete step-record retirement and GC proof | Follow-up |
| Build cache-mount accounting, prune, and GC | Landed |
| Additional Dockerfile compatibility | Evidence-gated |

## Delivery Strategy

### C5a — Close The Real-Workload Differential

Run the frozen target through the pinned Docker/BuildKit baseline and `spore
build`, then compare the selected output with the existing scanner contract.
Normalize only differences the durable compatibility contract explicitly
allows, such as Spore rootfs identities and Docker layer metadata. File paths,
types, bytes, modes, ownership, symlink targets, relevant xattrs, and final OCI
runtime configuration must match.

Exercise cache behavior against the same frozen input:

1. a cold build from isolated caches;
2. an unchanged warm rebuild that boots no VM;
3. a change to one copied source that invalidates its dependent suffix and
   changes the selected image;
4. an unrelated source change that does not permit stale output or silently
   alter the selected result; and
5. build-arg, base, and lockfile changes where the frozen target exposes those
   boundaries.

Keep source revision, Dockerfile digest, commands, selected image identities,
normalized scan digests, cache state, and bounded logs with the result. If the
oracle finds a mismatch, land the smallest owning parser, transition, executor,
or cache fix with a focused fixture before rerunning the complete acceptance
matrix.

This slice is done when the unchanged frozen target has matching normalized
output and every exercised invalidation case either reuses the exact correct
result or executes the required suffix. A parser success and bootable image are
not enough.

### C5b — Close The Wrapper And Benchmark Path

Run the downstream `buildkite-sporevm` wrapper against the exact accepted
SporeVM and workload revisions. Keep SporeVM generic: the wrapper may prepare
its context, named VM, and workload inputs, but a missing product primitive must
be planned separately rather than hidden as Buildkite-specific behavior.

Record at least:

- wrapper input preparation and context freshness time;
- `spore build` planning, cache lookup, VM boot, executed-step, checkpoint, and
  publication time;
- cold, unchanged warm, and one-file incremental wall time;
- named create/restore readiness and `bin/setup` time;
- the representative RSpec command and result; and
- cache/rootfs bytes needed to explain a material regression.

The output must retain exact revisions, binary identity, commands, environment,
logs, and machine-readable summaries so a later run can distinguish product
regression from context preparation, queueing, or host noise.

This slice is done when the complete wrapper has a repeatable baseline and a
one-file change demonstrates the intended prepare-once, execute-the-suffix
behavior without a hidden full context or image rebuild.

### C5c — Retire Obsolete Step Records Safely

Define retirement from reachability rather than age alone. Current records,
image refs, runtime manifests, durable pins, and every other documented root
must keep their selected indexes and objects alive. Complete older builder
records remain roots until a bounded operation can prove they are no longer
needed; malformed known records may remain misses and unknown future record
kinds must stay conservative roots.

The first implementation should reuse the existing rootfs-cache lock and GC
marking model. It must cover concurrent build publication, interruption at each
record/index/object boundary, corrupt or oversized records, shared children,
and retry after failure. Do not add a second CAS collector or delete records as
a side effect of ordinary warm lookup.

This slice is done when obsolete known records can be selected and retired
without changing image/ref behavior, while a concurrent or interrupted
operation cannot expose a missing child index or object.

### C6 — Evidence-Gated Compatibility

After C5 closure, use public corpus failures to choose any new feature. Likely
candidates include COPY ownership/mode flags, local or checksum-pinned ADD,
additional image-config instructions, and broader non-credential mount forms.
Each candidate needs its own result semantics, cache identity, failure policy,
security boundary, differential fixture, and fuzz updates.

Credential-bearing SSH or secrets require a separate named credential-broker
product and security plan. Additional persistent disks, portable cache mounts,
or new manifest/device state likewise require their own design rather than an
incremental builder flag.

There is no completion condition for general parity. A feature lands because a
real workload needs it and the bounded implementation is worth carrying.

## Verification

The normal local graph is:

```bash
mise run test
mise run build
mise run test:spore-build-conformance
```

Buildkite runs the same differential fixture set as four deterministic shards,
balanced by initial builds and transitions. Sharding changes only CI scheduling;
the local command above remains the complete serial conformance gate. The
VM-backed build smoke runs once alongside those shards, retaining its full log
as an artifact while successful jobs print only the final summary. Buildkite
collapses the ReleaseSafe and Buildx setup sections and leaves the conformance
case section expanded, so the job log opens on the useful output.

Each Linux agent retains its pinned BuildKit v0.30.0 builder state in a bounded
Docker volume. The agent name scopes the volume so concurrent jobs never share
a live builder, while later jobs on that agent reuse BuildKit layers. Startup
removes any stale builder container left by an interrupted job before attaching
the retained volume. BuildKit garbage collection caps each agent cache at 4 GB,
reserves 2 GB from
reclamation, and preserves 20 GB of host free space. The harness applies those
limits when it starts the builder, then prunes mutable `RUN` cache-mount state
so cross-build reuse cannot change the fixtures' cold-cache semantics. It also
removes each Docker-loaded oracle image as soon as the case finishes, while the
immutable BuildKit layers remain reusable in the retained volume.
Transitions that inspect cache-excluded transport metadata, such as bind-source
mtime, first prove the semantic cache hit and then request a fresh Docker
comparison so a retained layer cannot replay an earlier job's oracle bytes.
Buildx v0.33.0 is installed by mise only for these jobs and retained in a
per-agent cache on the host's fast scratch disk.

Capacity and publication changes additionally run:

```bash
mise run smoke:build-rootfs-capacity
mise run smoke:build-publication
```

The C5 real-workload gate runs on Linux ARM64/KVM with the frozen workload and
Docker/BuildKit baseline. Backend-neutral builder changes also keep the normal
HVF graph green; a change to VM execution, sandboxing, capacity, mount lifetime,
or checkpoint publication needs matching KVM and HVF evidence.

Every newly accepted attacker-influenced syntax or guest request extends the
owning parser fuzz target in the same change. Every cache-input rule gets a
golden invalidation test and at least one differential fixture.

## Resolved Decisions

- The supported user contract lives in `docs/spore-build.md`; this plan tracks
  only remaining work and future decision gates.
- SporeVM matches final filesystem and OCI runtime configuration for accepted
  features, not BuildKit layer identity or exact cache keys.
- The complete Dockerfile is parsed and planned before execution or network
  access.
- Uncached work runs in one persistent VM and publishes rootfs indexes, not
  Docker layers.
- Cache correctness wins over hit rate; conservative invalidation is allowed,
  stale output is not.
- `--no-cache` bypasses Dockerfile result reads but still reuses infrastructure
  normalization such as OCI materialization and `PREPARE`.
- The frozen Buildkite target is an ordering and acceptance oracle, not a source
  of product-specific features.
- Real credential forwarding, privileged execution, remote shared cache, and
  new persistent device state stay outside this roadmap.

## Deferred Decisions And Triggers

- Revisit automatic build capacity above 16 GiB only after a compact index or a
  lower proven dense-index ceiling removes the current format bound.
- Add a credential broker only for a concrete workflow whose trust, revocation,
  audit, and guest-delivery requirements justify a separate product surface.
- Consider OCI or registry output only if a real distribution workflow cannot
  use local images plus SporeVM pack/push/pull.
- Consider remote shared build cache only after the local cache's trust,
  retirement, and invalidation contracts are complete and measured transfer is
  the remaining limit.

## Key Learnings From Pressure-Testing

- A large unchanged Dockerfile is a good ordering oracle, but parser progress
  is not correctness proof. The remaining gate compares the complete selected
  result and its invalidation behavior.
- Wrapper context preparation can dominate a fast builder cache hit, so product
  performance claims must measure the complete entry point.
- Cache records are storage roots. Retirement needs the same conservative
  reachability and publication discipline as CAS collection.
- Mutable cache-mount bytes are not step-record children. Keeping the existing
  aggregate as the cleanup unit avoids a second metadata graph, while the
  build-wide process lock provides active-use safety without stale leases.
- Mount and credential syntax can look like a small compatibility addition while
  changing host authority. Those features keep separate security and product
  decision gates.
- Landed implementation history belongs in durable contracts, release notes,
  tests, and git history. Keeping it in the active plan made current support and
  remaining work contradict each other.
