---
status: landed
last_reviewed: 2026-06-18
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/rootfs.md
  - docs/spore-format.md
  - docs/plans/distribution.md
  - src/run.zig
  - src/resume.zig
  - src/spore.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/distribution.md
---

# Immutable Rootfs Resume Plan

## Summary

Local immutable rootfs resume has landed. This file is the local rootfs resume
contract and safety record. A spore captured from
`spore run --image ... --capture` records the exact read-only ext4
rootfs artifact it needs: BLAKE3 digest, size, virtio-blk binding, and OCI
provenance. `spore resume` resolves that artifact from the local digest cache,
verifies the same read-only fd it will attach, and fails before VM creation when
the artifact is missing or mismatched.

Active remote preparation no longer lives in this plan. Pull-based bundle,
preload, push, pull, and cache work is tracked in
`docs/plans/distribution.md`, while preserving the invariant that the ext4
digest is restore authority.

## Landed Local Contract

```console
spore run --image docker.io/library/ruby:3.3-alpine \
  --capture ruby-counter.spore \
  --capture-on USR1 \
  -- ruby -e 'STDOUT.sync = true; i = 0; loop { puts "ruby counter #{i}"; i += 1; sleep 1 }'

spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
spore fanout ruby-counter.children --parallel --for 20s
```

The captured manifest includes one optional `rootfs` artifact section:

```json
{
  "rootfs": {
    "kind": "immutable-ext4-rootfs-v0",
    "mode": "read-only",
    "device": {
      "kind": "virtio-mmio",
      "role": "rootfs",
      "virtio_device_id": 2,
      "mmio_slot": 1
    },
    "artifact": {
      "digest": "blake3:<hex>",
      "size": 123456789,
      "format": "ext4"
    },
    "source": {
      "kind": "oci-image",
      "requested_ref": "docker.io/library/ruby:3.3-alpine",
      "resolved_image_ref": "docker.io/library/ruby@sha256:<manifest>",
      "image_manifest_digest": "sha256:<manifest>",
      "platform": "linux/arm64",
      "builder_version": "sporevm-rootfs-v1"
    }
  }
}
```

The content digest is the primary identity. OCI metadata is provenance and a
possible preload input, not proof that local ext4 bytes are correct.

## Current State

- `src/spore.zig` defines and validates the immutable rootfs manifest field.
- `src/run.zig` records rootfs artifact identity when a captured run uses
  `--image`.
- `spore rootfs import-oci` imports a local OCI layout directory or buildx
  OCI-layout tar into the deterministic rootfs cache under a host-local
  `local/<name>:<tag>` ref.
- The rootfs cache has a digest-addressed path:

  ```text
  rootfs/
    <cache-key>.ext4
    <cache-key>.json
    by-digest/blake3/<hex>.ext4
  ```

- `src/resume.zig` accepts diskless spores and spores with one verified immutable
  rootfs artifact. Unknown, writable, missing, or unverifiable disk dependencies
  fail before VM creation.
- `spore fork` preserves the rootfs artifact reference in child manifests.
- `scripts/smoke-rootfs-fanout.sh` validates local capture, fork, and parallel
  product resume of a Ruby OCI rootfs workload.

## Safety Invariants

- Rootfs artifacts are opened read-only by the host and mounted read-only by the
  guest.
- The manifest never trusts local paths as portable identity.
- Resume verifies digest and size on the same fd it passes to the backend.
- Unknown or writable disk dependencies fail closed.
- OCI tags are resolved before capture; captured spores store digest-pinned refs.
- OCI rebuilds are explicit preload convenience, not resume authority.
- The rootfs cache uses digest-derived filenames, not manifest-provided paths.
- Rootfs-backed capture requires quiescent virtio-blk queues. Serializing pending
  read-only block requests is deferred.

## Distribution Boundary

Remote same-class fan-out needs exact rootfs bytes to stay available wherever
resume verifies them. The remaining remote distribution and cache sequence
belongs to `docs/plans/distribution.md`.

The distribution plan currently owns:

1. Preserve default exact immutable rootfs artifact inclusion through remote
   push/pull.
2. Keep metadata-only prepared-cache workflows explicit: distribution bundles
   may opt out of rootfs bytes only through the indexed bundle CLI, and
   materialization must verify the destination digest cache before writing a
   resumable spore.
3. Prefer exact ext4 bytes over OCI rebuilds for the first remote demo, because
   rebuilds can drift with tooling even when OCI provenance is stable.
4. Document the same-class Linux/KVM aarch64 host requirement.
5. Refuse remote resume when the rootfs is absent, hash-mismatched, or the host
   platform contract is incompatible.
6. Keep rootfs artifacts distinct from memory chunks inside the broader
   distribution bundle model.

This plan remains the source for the rootfs-specific resume invariant: resume
must verify the exact digest-addressed fd it attaches, and OCI provenance is not
restore authority.

## Deferred Work

- `spore rootfs import PATH` for arbitrary local rootfs images.
- Standalone `spore rootfs preload SPORE` for local artifact preparation after
  the distribution plan lands bundle-default rootfs inclusion.
- Additional prepared-cache UX beyond the indexed bundle `metadata-only` policy.
- Automatic OCI rebuild during `spore resume`, if product UX later justifies
  network and toolchain dependency in the resume path.
- Serialization of pending read-only virtio-blk requests at capture time.
- Rootfs cache garbage collection.
- OCI runtime defaults and image policy.
- Writable disks, writable overlays, or persisted guest disk mutations.
- Cross-backend HVF-to-KVM rootfs-backed resume.

## Verification

- Unit tests for manifest parsing, missing rootfs fields, unknown rootfs kinds,
  unknown digest algorithms, writable mode, wrong device binding, and malformed
  provenance.
- Unit tests for digest cache resolution, tampered rootfs bytes, descriptor type
  checks, symlink handling, and missing files.
- Unit tests for `spore fork` preserving the rootfs reference.
- Local smoke: `mise run smoke:rootfs-fanout`.
- Negative smoke: delete or corrupt the digest-cached rootfs and confirm
  `spore resume` refuses to boot.
- Distribution smoke coverage for rootfs-backed bundles lives in
  `docs/plans/distribution.md`.

## Resolved Decisions

- The rootfs contract is immutable and read-only.
- The ext4 content digest is restore authority.
- OCI digest metadata is provenance and explicit preload input.
- v0 `spore resume` does not implicitly rebuild missing rootfs artifacts.
- `--image` is the first portable capture path because it already has resolved
  OCI metadata.
- `spore run --rootfs PATH --capture` is rejected until import/preload
  records content identity and provenance. Plain `spore run --rootfs PATH` keeps
  working.
- Fork copies rootfs references, not rootfs bytes.
- Distribution bundles copy exact rootfs bytes by default so a clean compatible
  destination can materialize and verify the spore without an OCI rebuild.
- Metadata-only rootfs bundle behavior depends on explicit bundle metadata and is
  not part of the first exact-rootfs bundle slice.
