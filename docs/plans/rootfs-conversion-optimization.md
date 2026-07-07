---
status: active
last_reviewed: 2026-07-07
spec_refs:
  - docs/filesystem.md
  - docs/rootfs.md
  - SECURITY.md
  - src/rootfs.zig
  - src/rootfs_cas.zig
  - src/run.zig
---

# Rootfs Conversion Optimization Plan

## Summary

SporeVM should keep OCI and BuildKit outputs as inputs, keep the guest-visible
filesystem as a normal virtio-blk ext4 disk, and optimize the conversion step
between those two worlds.

The first useful optimization is an explicit local-only rootfs storage policy
for imported images. `spore rootfs import-oci` should be able to materialize the
deterministic flat ext4 artifact, install it into the digest cache, record the
local ref, and skip immediate rootfs CAS preload when the caller only needs a
fast local run. The existing chunked rootfs CAS path remains the default and
remains required for portable saved spores, bundles, pulls, and dedupe.

This is not a new guest-visible filesystem: the guest still sees virtio-blk
ext4. It is a new rootfs production and cache policy inside SporeVM's
runtime/storage layer. Runtime restore already serves the root disk from a flat
digest-addressed ext4 artifact, and that should stay true. Chunked
`rootfs.storage` is distribution and dedupe metadata. The plan is to delay
paying for that derived metadata until a workflow actually needs it.

## Problem

The current BuildKit-to-SporeVM path spends too much time after BuildKit has
already produced image bytes:

```bash
docker buildx build \
  --platform linux/arm64 \
  --output type=oci,dest=/tmp/app.oci \
  .

spore rootfs import-oci /tmp/app.oci \
  --ref local/app:dev \
  --platform linux/arm64
```

`import-oci` validates the layout, applies layers into staging, creates the
deterministic ext4 image, hashes and installs the flat artifact, and then
immediately scans the installed artifact into chunked rootfs CAS objects. That
last preload is valuable for portable saved spores, but it is wasted work for a
fresh local `spore run --image local/app:dev` that is not being saved or packed.

The recent Buildkite benchmark showed that changing the BuildKit export shape
from OCI layout to rootfs tar is not enough:

| Path | Wall | BuildKit output send | Spore import | Artifact |
| --- | ---: | ---: | ---: | ---: |
| OCI export + `import-oci` | 538.68s | 24.8s | 408.25s | 3.4G |
| Tar export + `import-tar` | 552.12s | 49.9s | 426.43s | 4.1G |

Tar extraction was faster in isolation (`layer_extract_staging` 83.80s versus
106.31s), but the end-to-end path lost time elsewhere. The larger costs in the
OCI run were `rootfs_cas_preload` 137.28s, `digest_cache_install` 55.47s,
`rootfs_blake3` 49.31s, and ext4 creation/finalization about 50.97s. That says
the first lever is avoiding or deferring duplicate conversion/cache passes, not
inventing a Dockerfile builder or making the runtime natively OCI.

## Goals

- Make local BuildKit imports materially faster when the caller only needs a
  local image ref for immediate run.
- Keep the default import behavior portable and compatible by preserving the
  current chunked rootfs CAS write path unless the caller opts into flat-only
  storage.
- Reuse the current digest-addressed ext4 artifact as the runtime base.
- Reuse the existing lazy `ensureImageRootfsStorage` upgrade path when a saved
  image-created spore needs manifest-bound chunked storage.
- Keep benchmark evidence attached to every default-policy change.

## Non-Goals

- No Dockerfile executor or new builder from scratch.
- No native OCI runtime filesystem, OCI layer overlay, FUSE, 9p, or file index
  as restore authority.
- No switch from `import-oci` to `import-tar` as the recommended BuildKit path
  based on the current benchmark.
- No default change for portable image imports in the first slice.
- No manifest format change for `rootfs.storage`.
- No shared-cache trust expansion. The verify-at-install, trust-at-open cache
  contract remains scoped to the existing per-user local cache model.

## Target Model

Add a rootfs import storage policy:

```bash
spore rootfs import-oci /tmp/app.oci \
  --ref local/app:dev \
  --platform linux/arm64 \
  --rootfs-storage=flat
```

Supported values:

- `chunked`: current behavior. Build/import writes the flat ext4 artifact,
  installs it into the digest cache, preloads chunked rootfs CAS, and writes
  `rootfs_storage` into the rootfs metadata sidecar. This remains the default.
- `flat`: local-only behavior. Build/import writes the flat ext4 artifact and
  installs it into the digest cache, but skips rootfs CAS preload and records no
  `rootfs_storage` descriptor until a later workflow asks for one.

For the first implementation slice, expose this on `spore rootfs import-oci`.
If the active `import-tar` command is kept, it should accept the same option so
benchmark experiments compare storage policy rather than unrelated CLI shape.
`spore rootfs build` can keep the current chunked behavior until there is a
registry-build caller that needs the same opt-in.

Flat imports still produce a normal local image ref:

```bash
spore rootfs import-oci /tmp/app.oci \
  --ref local/app:dev \
  --rootfs-storage=flat

spore run --image local/app:dev 'make test'
```

The run path can use the digest-addressed ext4 artifact exactly as it does
today. If the caller later saves the image-created VM, the existing
`ensureImageRootfsStorage` hook should detect the missing metadata descriptor,
preload rootfs CAS from the flat artifact once, update the metadata sidecar, and
record portable `rootfs.storage` in the spore manifest:

```bash
spore run --image local/app:dev --save app.spore 'make warm-cache'
```

That makes flat mode an import-time optimization, not a permanent downgrade.
The first saved/packed portable use pays the chunking cost explicitly and only
once for that image cache entry.

## Safety Model And Invariants

- The guest-visible disk remains virtio-blk ext4. The storage policy only
  chooses whether derived rootfs CAS is created during import.
- The flat digest-addressed ext4 artifact remains the runtime base source.
  Chunked rootfs CAS remains a materialization and distribution format.
- A metadata sidecar without `rootfs_storage` must not be treated as portable
  chunked storage. Callers that require it must either derive it through
  `ensureImageRootfsStorage` or fail closed with an actionable error.
- If a spore manifest records `rootfs.storage`, the descriptor and objects must
  be complete and validate against the rootfs artifact exactly as today.
- OCI layout and tar parsing stay fail-closed and outside the VMM monitor
  process. This plan should not add new attacker-influenced parser surfaces.
- Existing chunked manifests, bundles, pulls, and exact-rootfs escape hatches
  keep their current semantics.

## Current State

`docs/filesystem.md` is the durable contract: restore authority is manifest
state, product restore serves the flat ext4 artifact, and `rootfs.storage` is
distribution/dedupe metadata.

`src/rootfs.zig` funnels registry builds, OCI layout imports, and rootfs tar
imports through `materializeRootFS`. Before this plan, that function always:

1. applies verified layers into staging,
2. creates and finalizes deterministic ext4,
3. BLAKE3-hashes the ext4 output,
4. installs the artifact into the digest cache,
5. ran `rootfs_cas.preload`,
6. wrote metadata with a non-optional `rootfs_storage` field.

`src/run.zig` already calls `ensureImageRootfsStorage` when `spore run --image
... --save` needs to record a portable image-created rootfs. That function
already handles older or incomplete metadata by running `rootfs_cas.preload`
and writing the descriptor back to the metadata sidecar.

`SPOREVM_ROOTFS_BUILD_PROFILE=1` already emits phase timings, including
`rootfs_cas_preload`, so the first slice can be measured without inventing a
new profiler.

## Delivery Strategy

### Slice 1: Opt-In Flat Local Imports

Status: implemented in this branch.

Add a `RootfsStoragePolicy` enum with `chunked` and `flat`. Thread it through
`ImportOciRequest`, import option parsing, API request structs, and
`MaterializeOptions`.

In `materializeRootFS`, keep the current path for `chunked`. For `flat`, skip
`rootfs_cas.preload`, make the in-memory build result and metadata sidecar
represent `rootfs_storage` as absent, and keep digest-cache installation
unchanged.

Definition of done:

- `spore rootfs import-oci ... --rootfs-storage=flat` creates a local ref that
  resolves and runs through `spore run --image local/...`.
- Profile output for flat imports has no `rootfs_cas_preload` phase.
- Default `spore rootfs import-oci ...` still writes complete chunked storage.
- Metadata parsing accepts absent `rootfs_storage` for local image refs while
  existing descriptors still validate exactly.
- `mise run test`, `mise run build`, and `git diff --check` pass.

Implementation notes:

- `spore rootfs import-oci ... --rootfs-storage=flat` and `spore rootfs
  import-tar ... --rootfs-storage=flat` skip immediate rootfs CAS preload.
- The default `chunked` policy keeps the existing preload and metadata
  descriptor behavior.
- `spore rootfs build` remains chunked-only for this slice, so the public build
  result still carries a non-optional rootfs storage descriptor.
- Flat metadata omits `rootfs_storage`; later portable workflows use the
  existing lazy upgrade path rather than trusting partial storage metadata.

### Slice 2: Lazy Portable Upgrade

Status: implemented in this branch.

Pin the expected behavior when flat imports are later used by portable
workflows. `spore run --image local/... --save` should derive chunked
`rootfs.storage` once, update the metadata sidecar, and write the manifest with
complete portable storage. Any path that cannot derive storage from the flat
artifact must fail before guest execution or bundle publication.

Definition of done:

- A flat-imported local ref can be saved, and the resulting manifest contains
  valid `rootfs.storage`.
- The second save from the same local ref reuses the cached descriptor instead
  of preloading CAS again.
- `spore pack` behavior remains unchanged for saved spores: chunked manifests
  bundle chunked storage, and spores without storage use exact rootfs bytes or
  explicit metadata-only policy.

Implementation notes:

- The run-path unit coverage now exercises metadata without `rootfs_storage`,
  calls the same `resolvedImageRootfsInput` path used when save records an
  image-created rootfs, and asserts that the returned manifest rootfs includes
  complete storage.
- The same test checks that the metadata sidecar is upgraded with
  `rootfs_storage` and that a follow-up `ensureImageRootfsStorage` call reuses
  the recorded descriptor.

### Slice 3: Buildkite Before/After Benchmark

Run the same Buildkite workload that produced the OCI versus tar comparison,
but keep the BuildKit export as OCI and change only the import storage policy:

```bash
SPOREVM_ROOTFS_BUILD_PROFILE=1 \
spore rootfs import-oci /tmp/app.oci \
  --ref local/app:dev \
  --platform linux/arm64

SPOREVM_ROOTFS_BUILD_PROFILE=1 \
spore rootfs import-oci /tmp/app.oci \
  --ref local/app:dev \
  --platform linux/arm64 \
  --rootfs-storage=flat
```

Expected result: flat mode should remove most of the previous
`rootfs_cas_preload` wall time from the first local import. If the measured
improvement is not close to the skipped phase cost, do not change wrapper
defaults; investigate the next largest phases first.

Definition of done:

- Record wall time, BuildKit output time, Spore import time, and profile phase
  totals for both modes.
- Run a warm `spore run --image local/...` after each import to prove the local
  ref is useful.
- Run a save from the flat-imported ref to measure the deferred upgrade cost
  separately from first-run import cost.

### Slice 4: Reduce Duplicate Passes

After flat import is measured, attack the next bottleneck with evidence. Likely
candidates are duplicate full-file hashing between `rootfs_blake3`,
`digest_cache_install`, and `rootfs_cas.preload`, and expensive ext4
finalization on large trees.

This slice should not start with a broad abstraction. It should start by adding
or improving phase evidence so each optimization removes one measured full pass
or one measured tool invocation.

## Verification

- Unit tests for option parsing and metadata with absent `rootfs_storage`.
- Existing rootfs tests for chunked default behavior.
- `mise run test`.
- `mise run build`.
- `git diff --check`.
- Manual import/run smoke for a tiny OCI layout or fixture.
- Buildkite before/after benchmark for the target large image.
- Save smoke from a flat-imported ref proving lazy upgrade writes valid
  `rootfs.storage`.

## Resolved Decisions

- Keep OCI layout as the primary BuildKit interchange format for now. The tar
  export experiment did not improve end-to-end time.
- Keep the guest-visible runtime filesystem block-authoritative and
  ext4-backed. OCI remains input provenance, not guest restore authority.
- Make flat storage opt-in first. Do not change the default until benchmark
  evidence proves local-import wins without surprising portable workflows.
- Use lazy CAS derivation for portability. Do not store fake or partial
  `rootfs.storage` descriptors.
- Prefer `--rootfs-storage=flat|chunked` over a shorter `--storage` flag so the
  user-facing option names the specific derived artifact being controlled.

## Deferred Work

- Exposing the same storage policy on `spore rootfs build` and direct
  registry-backed `spore run --image` workflows.
- A first-class benchmark command that emits machine-readable phase timings.
- Further ext4 materialization optimizations once flat import identifies the
  next bottleneck.
- File-content indexes or OCI-aware dedupe for distribution, if block-level
  chunking leaves measured transfer savings on the table.

## Key Learnings From Pressure-Testing

The main failure mode is operator confusion: a fast local import might be
mistaken for a portable image. The plan avoids that by making flat mode opt-in,
omitting `rootfs_storage` rather than writing partial metadata, and relying on a
lazy upgrade or fail-closed behavior when portability is required.

The second risk is optimizing the wrong boundary. The tar experiment was useful
because it disproved the idea that OCI layout ceremony dominates the workload.
The first implementation slice therefore changes only when derived rootfs CAS is
created, and the benchmark slice changes only one variable at a time.

The third risk is widening the attack surface. Flat mode does not add a parser
or a new guest-visible filesystem; it changes when existing verified ext4 bytes
are scanned into existing chunked storage. That keeps the security review
focused on metadata optionality and fail-closed upgrade paths.
