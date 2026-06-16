---
status: active
last_reviewed: 2026-06-16
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/rootfs.md
  - docs/spore-format.md
  - src/run.zig
  - src/resume.zig
  - src/spore.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
---

# Immutable Rootfs Resume Plan

## Summary

Local immutable rootfs resume has landed. A spore captured from
`spore run --image ... --capture-on-abort` records the exact read-only ext4
rootfs artifact it needs: BLAKE3 digest, size, virtio-blk binding, and OCI
provenance. `spore resume` resolves that artifact from the local digest cache,
verifies the same read-only fd it will attach, and fails before VM creation when
the artifact is missing or mismatched.

The active work is now remote preparation: make the same rootfs artifact
available on compatible hosts without rebuilding or copying it per child, while
preserving the invariant that the ext4 digest is restore authority.

## Landed Local Contract

```console
spore run --image docker.io/library/ruby:3.3-alpine \
  --capture-on-abort ruby-counter.spore \
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

## Active Slice: Remote Preparation

Remote same-class fan-out needs a way to put exact rootfs bytes where resume can
verify them.

Default next slice:

1. Add an exact-byte preload or bundle path for immutable rootfs artifacts.
2. Prefer exact ext4 bytes over OCI rebuilds for the first remote demo, because
   rebuilds can drift with tooling even when OCI provenance is stable.
3. Document the same-class Linux/KVM aarch64 host requirement.
4. Refuse remote resume when the rootfs is absent, hash-mismatched, or the host
   platform contract is incompatible.
5. Reuse the foundation bundle/cache concepts where practical, but keep rootfs
   artifacts distinct from memory chunks until a broader artifact bundle format is
   designed.

Done when the same captured/forked rootfs workload can be distributed to prepared
same-class aarch64 KVM hosts without rebuilding or copying rootfs bytes per
child.

## Deferred Work

- `spore rootfs import PATH` for arbitrary local rootfs images.
- Final command shape for preload: likely `spore rootfs preload SPORE` for local
  artifact preparation, with host-targeted distribution layered later.
- `spore pack --include-rootfs` or an equivalent artifact bundle.
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
- Later remote smoke on same-class Linux/KVM aarch64 hosts after preload or
  bundle support lands.

## Resolved Decisions

- The rootfs contract is immutable and read-only.
- The ext4 content digest is restore authority.
- OCI digest metadata is provenance and explicit preload input.
- v0 `spore resume` does not implicitly rebuild missing rootfs artifacts.
- `--image` is the first portable capture path because it already has resolved
  OCI metadata.
- `spore run --rootfs PATH --capture-on-abort` is rejected until import/preload
  records content identity and provenance. Plain `spore run --rootfs PATH` keeps
  working.
- Fork copies rootfs references, not rootfs bytes.
