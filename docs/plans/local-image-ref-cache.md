---
status: active
last_reviewed: 2026-06-16
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/lifecycle-monitor.md
  - docs/rootfs.md
  - src/local_paths.zig
  - src/run.zig
  - src/rootfs.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/lifecycle-monitor.md
  - docs/plans/immutable-rootfs-resume.md
---

# Local Image Ref Cache Plan

## Summary

`spore run --image <tag>` and `spore create --image <tag>` should behave like a
local runtime with a content-addressed rootfs cache, not like a fresh registry
inspection tool on every invocation.

The current rootfs cache is keyed by immutable image identity, platform, and the
rootfs builder version. That is the right correctness boundary and should not
change. The missing piece is a small local ref record that maps a mutable input
tag, such as `docker.io/library/ruby:3.3-alpine`, to the digest-pinned rootfs
cache entry already validated and materialized on this host.

The first slice should make warm mutable-tag runs use local metadata without a
registry round trip. Registry truth remains available through an explicit pull
policy.

## Problem

Warm `--image` runs are currently dominated by resolving mutable OCI tags. The
fast path for digest-pinned refs can address the rootfs cache directly, but a
tag must be resolved before SporeVM can know which immutable cache key to check.

For Docker Hub from the current local network, resolving
`docker.io/library/ruby:3.3-alpine` takes about 3.6-3.8s. The same cached image
addressed by digest runs in roughly the same time as diskless `spore run`,
about 0.15-0.20s. The user-visible problem is that a cached rootfs still feels
cold when addressed through its original tag.

## Goals

- Preserve immutable rootfs cache keys based on resolved image digest, platform,
  builder version, and material build options.
- Add a direct-addressed local ref cache for mutable image inputs.
- Make the default warm path avoid registry access when the local ref record and
  referenced rootfs are valid.
- Keep captured spore manifests digest-pinned and portable. Mutable tags remain
  input convenience only.
- Make refresh behavior explicit with Docker-like pull policy.
- Avoid directory scans in the hot path.

## Non-Goals

- No Docker daemon integration.
- No hidden indefinite registry freshness guarantee.
- No tag-based rootfs cache keys.
- No OCI Entrypoint, Cmd, User, Env, or Workdir semantics in this slice.
- No registry auth redesign.
- No garbage collection policy in the first slice. A later slice added explicit
  `spore system df` and `spore system prune --rootfs` commands.

## Target Model

The default policy is local-first:

```console
spore run --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
spore create bench-ruby --image docker.io/library/ruby:3.3-alpine
```

If a valid local ref record exists and points at an existing validated rootfs,
SporeVM uses it without network access. If no local record exists, SporeVM falls
back to the existing registry resolution and rootfs build/reuse path, then writes
the ref record.

Explicit pull policy controls mutable-tag freshness:

```console
spore run --pull=missing --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
spore run --pull=always --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
spore run --pull=never --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
```

- `missing`: default. Use a valid local ref record if present; otherwise resolve
  from the registry.
- `always`: resolve from the registry and update the local ref record.
- `never`: require a valid local ref record and rootfs cache hit; fail closed
  otherwise.

Digest-pinned refs keep the existing direct path and do not require a ref
record.

## Cache Shape

Use the existing rootfs cache root from `src/local_paths.zig`:

```text
$SPOREVM_ROOTFS_CACHE_DIR/
  <rootfs-cache-key>.ext4
  <rootfs-cache-key>.json
  refs/
    <ref-key>.json
```

The ref key is a digest of the lookup identity:

```text
sporevm-rootfs-ref-v1
requested_ref
platform
builder_version
```

The file stores human-readable metadata and the immutable cache target:

```json
{
  "version": 1,
  "requested_ref": "docker.io/library/ruby:3.3-alpine",
  "platform": "linux/arm64",
  "builder_version": "sporevm-rootfs-v3",
  "resolved_image_ref": "docker.io/library/ruby@sha256:f22bbb...",
  "image_manifest_digest": "sha256:f22bbb...",
  "rootfs_cache_key": "d78e3ac...",
  "resolved_at_unix": 1781560000
}
```

The warm lookup is direct:

1. Compute `<ref-key>` from the requested ref, platform, and builder version.
2. Read `refs/<ref-key>.json`.
3. Verify the record fields match the lookup identity.
4. Read `<rootfs-cache-key>.json` and verify it matches the resolved image
   identity and builder version.
5. Verify `<rootfs-cache-key>.ext4` exists as a regular file.
6. Run with that rootfs path.

No filesystem walk, glob, or metadata scan is needed.

## Safety Invariants

- A mutable tag record never replaces immutable identity in a spore manifest.
- Stale tag records can only point to an older immutable rootfs; they cannot
  cause a new rootfs to be mislabeled as another digest.
- Ref records are advisory cache metadata. If the referenced rootfs metadata or
  ext4 file is missing or mismatched, treat the ref record as a cache miss.
- Write ref records atomically after the rootfs metadata and ext4 are durable.
- Keep cache directories under the existing private local cache path and honor
  `SPOREVM_ROOTFS_CACHE_DIR`.

## Current State

- `spore run --image` and `spore create --image` share the direct image cache.
- Digest-pinned refs can hit the rootfs cache without registry access.
- Slice 1 is implemented: mutable tags check a direct-addressed local ref record
  before registry resolution, then update that record after the referenced
  rootfs cache entry is valid.
- The lifecycle benchmark already resolves mutable tags once before timed loops
  so benchmark numbers do not accidentally measure registry latency.

## Delivery Strategy

### Slice 1: Local Ref Records For Default Warm Runs

Status: landed in this plan slice.

Add ref-key computation, ref JSON read/write, and implicit local-first behavior
for `spore run --image` and `spore create --image`.

Done when the first `ruby:3.3-alpine` run may resolve or build, but the second
run uses the local ref record and lands near digest-pinned timing.

### Slice 2: Explicit Pull Policy

Status: next.

Add `--pull=missing|always|never` to `spore run` and `spore create`.

Done when `--pull=always` refreshes the ref record, `--pull=never` fails without
network when the local record is absent, and the default behavior remains
`missing`.

### Slice 3: Observability And Docs

Status: follow-up.

Expose cache decisions through debug logging and update rootfs docs.

Done when `--debug` clearly distinguishes local ref hit, local ref miss, forced
refresh, and rootfs cache hit.

## Verification

- Unit tests for ref-key stability and field validation.
- Unit tests for cache miss behavior when the ref record, metadata JSON, or ext4
  file is missing or mismatched.
- CLI tests for `--pull=missing`, `--pull=always`, and `--pull=never` parsing.
- Local smoke:

  ```console
  zig-out/bin/spore run --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
  zig-out/bin/spore run --image docker.io/library/ruby:3.3-alpine -- /bin/echo hi
  ```

  The second run should avoid registry access and match digest-pinned warm-run
  timing.

- Existing validation:

  ```console
  mise run test
  mise run build
  ```

## Key Learnings From Pressure-Testing

- A local ref cache is simpler and safer than Docker daemon integration because
  it keeps SporeVM's deterministic rootfs builder and digest verification as the
  source of truth.
- The cache must be direct-addressed by a digest key. Scanning rootfs metadata
  would make the hot path scale with cache size.
- Pull policy should be explicit before users learn the wrong freshness model.
  The default can be fast, but users need a clear way to force registry truth.
- TTL can wait. The first correctness boundary is whether the caller asked for
  local reuse, forced refresh, or no network.

## Resolved Decisions

- Use SporeVM's existing rootfs cache root, including `SPOREVM_ROOTFS_CACHE_DIR`.
- Keep rootfs cache keys immutable and digest-based.
- Use a hashed filename for ref records, not tag text in path names.
- Make `--pull=missing` the default once pull policy lands.
- Do not use the Docker daemon for this slice.

## Deferred Work

- Automatic background cache garbage collection.
- TTL or staleness warnings for mutable tag records.
- Importing images from a local daemon or OCI layout.
- Registry credential policy beyond the current direct-registry behavior.
