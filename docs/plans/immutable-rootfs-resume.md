---
status: active
last_reviewed: 2026-06-16
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/rootfs.md
  - src/fanout.zig
  - src/run.zig
  - src/rootfs.zig
  - src/resume.zig
  - src/spore.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
---

# Immutable Rootfs Resume Plan

## Summary

SporeVM already treats rootfs execution as read-only at runtime. The missing
piece is not writable disk capture; it is a restore contract that lets a
captured spore reattach the exact same immutable rootfs bytes on resume.

The first rootfs-backed resume path should record content identity in the spore
manifest, resolve the rootfs from a local content-addressed cache, verify the
bytes, attach the image read-only, and fail closed when any part of that
contract is missing. Forked spores should stay metadata-only and inherit the
same rootfs reference.

That gives the Ruby counter demo a product-shaped path without turning
SporeVM into a container runtime:

```console
spore run --image ruby-demo@sha256:... --capture-on-abort ruby-counter.spore -- ruby /demo/counter.rb
spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
spore fanout ruby-counter.children/ --parallel --for 20s
```

## Problem

Before this plan, `spore run --image` could build or reuse a cached
OCI-derived ext4 rootfs, attach it read-only, and execute an explicit argv, but
captures from that path were not product-resumable. The spore manifest recorded
virtio device state but did not record how to obtain and verify the backing
rootfs artifact.

Product `spore resume` therefore rejected all disk-backed spores. Removing that
rejection without a rootfs identity contract would have made resume depend on
ambient host paths, mutable cache state, or best-effort OCI rebuilds. That
would be fragile locally and unsafe across multiple hosts.

## Goals

- Define a v0 immutable rootfs manifest contract for read-only ext4 rootfs
  artifacts.
- Make `spore run --image ... --capture-on-abort SPORE` produce a spore that
  records the rootfs content identity and OCI provenance needed for later
  resolution.
- Make `spore resume SPORE` resolve the rootfs by content digest, verify the
  bytes, attach it read-only, and fail closed if verification or resolution
  fails.
- Keep `spore fork` metadata-only by copying the rootfs reference into child
  spores without copying rootfs bytes.
- Make the local Ruby/rootfs fan-out demo runnable through product `run`,
  `fork`, and `resume` commands.
- Keep the contract usable for future same-host-class multi-host fan-out by
  identifying rootfs content by digest rather than local path.

## Non-Goals

- No writable rootfs state capture in this plan.
- No OCI Entrypoint, Cmd, User, Env, Workdir, layer mount, volume, secret,
  network, or workspace semantics.
- No mutable tag identity in the spore contract. Tags may be accepted as input
  to `spore run --image`, but captured spores record digest-pinned image
  identity.
- No arbitrary local-path portability for `spore run --rootfs PATH` in the
  first slice. A local rootfs without provenance can be captured only if it is
  imported into the verified rootfs cache or marked as same-host-only and
  rejected by portable resume.
- No claim that Mac HVF captures can resume on AWS KVM. The first multi-host
  target is same-class Linux/KVM aarch64 hosts.
- No direct registry fan-out data plane. Remote hosts may preload, explicitly
  rebuild, or receive rootfs bytes, but resume still verifies content before
  boot.

## Current State

- `spore run --rootfs PATH` opens the rootfs read-only and the initrd mounts it
  read-only.
- `spore run --image REF` resolves REF to a linux/arm64 digest-pinned image
  identity, builds or reuses a cached deterministic ext4 rootfs, and delegates
  to the same read-only `--rootfs` execution path.
- `spore rootfs import-oci` imports a local OCI layout directory or buildx
  OCI-layout tar into the deterministic rootfs cache under a host-local
  `local/<name>:<tag>` ref.
- Rootfs build metadata records OCI identity such as `image_ref`,
  `resolved_image_ref`, `image_manifest_digest`, `platform`, and
  `builder_version`.
- The spore manifest currently contains platform, machine, virtio transport
  device state, generation state, memory chunks, and optional immutable rootfs
  artifact identity.
- Product `spore resume` now accepts diskless spores and spores with one
  verified immutable rootfs artifact. Unknown, writable, or unverifiable disk
  dependencies still fail before VM creation.
- `spore run --image ... --capture-on-abort` records rootfs BLAKE3, size,
  virtio-blk binding, resolved OCI identity, platform, and builder version.
- `spore run --rootfs PATH --capture-on-abort` is rejected until there is an
  import/preload command for arbitrary local rootfs identity.

## Progress Snapshot

- Implemented: manifest rootfs artifact types and validation in `src/spore.zig`.
- Implemented: digest-addressed rootfs cache helpers and descriptor-based
  verification in `src/run.zig`.
- Implemented: `spore run --image ... --capture-on-abort` records immutable
  rootfs metadata and requires quiescent virtio-blk queues at capture.
- Implemented: `spore resume` reopens the verified digest-cached rootfs fd and
  passes it to the existing backend resume path.
- Implemented: `spore fork` preserves the rootfs artifact reference in child
  manifests.
- Implemented: an opt-in Ruby OCI rootfs fan-out smoke that captures, forks,
  and resumes children in parallel through product commands. The rootfs agent
  publishes fork identity to `/run/sporevm/generation.json` and
  `/run/sporevm/env`; local `parallel_index/count` match batch-local
  `fork_index/count` until distributed offset/range semantics land.
- Implemented: local OCI layout import for buildx output without Docker daemon
  or registry access in SporeVM.
- Remaining: the remote preload or bundle UX.

## Target Model

### Manifest Contract

The spore manifest grows a rootfs artifact section that describes the immutable
bytes required by the virtio-blk root device. It should be separate from the
existing virtio transport state; transport state says how the device looked at
capture time, while the rootfs artifact says what backing bytes must be opened
on resume.

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
      "requested_ref": "docker.io/library/ruby:3.3",
      "resolved_image_ref": "docker.io/library/ruby@sha256:<manifest>",
      "image_manifest_digest": "sha256:<manifest>",
      "platform": "linux/arm64",
      "builder_version": "sporevm-rootfs-v1"
    }
  }
}
```

The content digest is the primary restore identity. OCI metadata is provenance
and a possible rebuild recipe, not proof that the local ext4 bytes are correct.
Resume must verify the rootfs file against the recorded digest and size before
attaching it.

Resume must also validate the artifact binding against the captured transport
state. The named virtio-mmio slot must exist, must have virtio device id 2
(`virtio-blk`), and every captured block device must have a supported immutable
artifact entry. A manifest with an unbound artifact, a block device without an
artifact, or a mismatched slot fails before VM creation.

### Cache And Resolution

The local rootfs cache needs a content-addressed lookup path in addition to the
current image-identity cache key:

```text
rootfs/
  by-image/<cache-key>.ext4
  by-image/<cache-key>.json
  by-digest/blake3/<hex>.ext4
```

`spore run --image` can keep using the image cache for fast local reuse, but
capture records the content digest of the ext4 file that was actually attached.
The implementation may hardlink or copy the file into `by-digest` after
hashing it. Resume resolves through `by-digest` first, verifies, and only then
opens the file read-only.

If `by-digest` is missing, v0 `spore resume` refuses to boot and tells the
operator to preload or bundle the exact rootfs artifact. This keeps resume
deterministic, avoids hidden registry credentials and network latency, and
keeps ext4 builder drift out of the restore hot path.

A later explicit preload command may use OCI provenance to rebuild from
`resolved_image_ref`, but the rebuilt file is accepted only if its bytes match
the recorded digest and size. If local tools produce different ext4 bytes,
preload fails and the operator must distribute the exact rootfs artifact.

### Resume Behavior

`spore resume` should distinguish three cases:

- Diskless spore: use the current path.
- Spore with an immutable read-only rootfs artifact: resolve from the local
  content-addressed cache, verify, attach read-only, then resume.
- Spore with any unknown, writable, or unverifiable disk dependency: reject
  before VM creation.

The guest-visible device model does not change. The rootfs still appears as the
existing virtio-blk device, and the initrd still mounts it read-only. The
change is in host-side artifact resolution and validation.

### Fork Behavior

`spore fork` copies the rootfs artifact reference into each child manifest.
Children do not copy rootfs bytes. A host resuming any child performs the same
resolve-and-verify step against the shared immutable rootfs content.

### Multi-Host Behavior

The same manifest contract works across same-class hosts because the spore
names the rootfs by content digest:

```console
spore preload --image ruby-demo@sha256:... host-a host-b host-c
spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
spore push ruby-counter.children/ host-a host-b host-c
```

`spore preload` and `spore push` are future product surfaces. The invariant for
this plan is simpler: each host must obtain the rootfs bytes before resume and
verify them against the manifest before VM creation. The first distributed
target remains same-class Linux/KVM aarch64 hosts; backend portability failures
still fail closed through the existing platform contract.

## Safety Invariants

- Rootfs artifacts are opened read-only by the host and mounted read-only by
  the guest.
- The spore manifest never trusts local paths as portable identity.
- Digest and size are verified on the same read-only file descriptor that will
  be attached to the VM. The implementation must not verify one path and then
  reopen another.
- Unknown disk dependencies fail before VM creation.
- OCI tags are resolved before capture; captured spores store digest-pinned
  refs.
- OCI rebuilds are explicit preload convenience, not resume authority. The
  rebuilt ext4 must match the recorded content digest.
- The rootfs cache uses digest-derived filenames, not manifest-provided paths.
- Capture must not leave unresolved virtio-blk requests that depend on
  host-only state. The first implementation should capture only when block
  device queues are quiescent; serializing pending read-only requests is later
  work.

## Delivery Strategy

### Slice A: Manifest Shape And Rootfs Hashing

Status: implemented in this branch.

- Add a rootfs artifact type to `src/spore.zig`.
- Add strict manifest parse/write tests for the new field.
- Compute BLAKE3 and size for rootfs files used by `spore run --image`.
- Record the artifact and OCI provenance when capture-on-abort produces a
  rootfs-backed spore.
- Keep `spore resume` rejecting those spores until Slice C resolution exists.

Done when a captured `--image` spore manifest names the exact immutable ext4
content and existing disk-backed resume rejection still fails closed.

### Slice B: Content-Addressed Rootfs Cache

Status: implemented in this branch.

- Add `by-digest` cache storage. The spore manifest carries the rootfs
  metadata needed for resume; the digest cache itself stores the verified ext4
  artifact.
- Move or hardlink image-cache outputs into the digest cache after hashing.
- Add verification helpers that open a digest-addressed rootfs, reject symlinks
  where the platform supports it, stream-hash that fd, check size, and return
  the same read-only fd for backend attachment.
- Treat symlinks, wrong size, digest mismatch, missing metadata, and unknown
  algorithms as hard failures.

Done when unit tests can verify a cached rootfs, reject tampered bytes, and
reject path-based manifests.

### Slice C: Local Immutable Rootfs Resume

Status: implemented in this branch.

- Replace the blanket disk-backed resume rejection with disk dependency
  classification.
- Permit only the read-only immutable rootfs artifact kind.
- Resolve the rootfs through `by-digest`; reject missing cache entries with an
  actionable preload or bundle error.
- Attach the verified fd to the backend resume path as read-only.
- Keep writable, unknown, or unverifiable disks rejected.
- Prove the block device has no pending host-only queue state before permitting
  rootfs-backed capture/resume. The first version should fail capture rather
  than serialize incomplete block requests.

Done when a local rootfs-backed spore captured from `spore run --image` resumes
through product `spore resume` without any caller-supplied disk path.

### Slice D: Forked Rootfs Fan-Out Demo

Status: implemented in this branch.

- Ensure `spore fork` preserves the rootfs artifact field.
- Add a rootfs-backed fan-out smoke that captures one long-running counter,
  forks it, and resumes multiple children in parallel.
- Resolve the demo image to a digest-pinned ref before capture. A friendly
  `ruby-demo` alias can be added later, but the smoke should use a real
  resolved image ref.

Done when the local Ruby or Ruby-like rootfs demo produces interleaved child
output through repeated product `spore resume` commands.

### Slice E: Remote Preparation

Status: not started.

- Add a preload or bundle path for exact rootfs bytes.
- Document the same-class Linux/KVM aarch64 host requirement.
- Refuse remote resume when the rootfs is absent, hash-mismatched, or the host
  platform contract is incompatible.

Done when the same captured/forked workload can be distributed to prepared
same-class aarch64 KVM hosts without rebuilding or copying rootfs bytes per
child.

## Verification

- Unit tests for manifest parsing, missing rootfs fields, unknown rootfs kinds,
  unknown digest algorithms, writable mode, wrong device binding, and malformed
  provenance.
- Unit tests for digest cache resolution, tampered rootfs bytes, descriptor
  type checks, symlink handling, and missing files.
- Unit tests for `spore fork` preserving the rootfs reference.
- Resume tests that prove diskless spores still work and unsupported disk
  dependencies still fail closed.
- A local smoke for `spore run --image ... --capture-on-abort`, `spore fork`,
  and parallel `spore resume`.
- A negative smoke that deletes or corrupts the digest-cached rootfs and proves
  `spore resume` refuses to boot.
- Later remote smoke on same-class Linux/KVM aarch64 hosts after the preload or
  bundle path exists.

## Resolved Decisions

- Rootfs runtime mutability is not part of this plan. The rootfs contract is
  immutable and read-only.
- The content digest of the ext4 artifact is the restore authority.
- OCI digest metadata is provenance and explicit preload input, not sufficient
  proof.
- v0 `spore resume` does not rebuild missing rootfs artifacts from OCI. Missing
  bytes are a preload or bundle problem.
- `--image` is the primary first capture path because it already has resolved
  OCI metadata.
- `spore run --rootfs PATH --capture-on-abort` is rejected until there is an
  import/preload command that records content identity and provenance. Plain
  `spore run --rootfs PATH` keeps working.
- Fork copies rootfs references, not rootfs bytes.
- The first rootfs-backed capture path requires quiescent virtio-blk queues and
  fails capture if queue state cannot be proven safe.
- Multi-host comes after local rootfs-backed resume and requires same-class
  host compatibility unless the broader backend portability plan proves more.

## Deferred Work

- `spore rootfs import PATH` for arbitrary local rootfs images.
- `spore preload` and `spore push` UX for prepared remote hosts.
- `spore pack --include-rootfs` or equivalent bundle support for exact rootfs
  byte distribution.
- Automatic OCI rebuild during `spore resume`, if product UX later justifies
  accepting network and toolchain dependency in the resume path.
- Serialization of pending read-only virtio-blk requests at capture time.
- Rootfs cache garbage collection.
- OCI runtime defaults and image policy.
- Writable disks, writable overlays, or persisted guest disk mutations.
- Cross-backend HVF-to-KVM rootfs-backed resume.

## Open Questions

- What exact command shape should preload use: `spore rootfs preload SPORE`,
  `spore preload SPORE`, or host-targeted preload? This is not blocking local
  resume because the capture host already has the digest-cached rootfs.
- Should remote distribution prefer exact-byte bundles first or OCI rebuilds
  first? The first remote slice should choose based on the AWS demo path.

## Key Learnings From Adversarial Review

- `spore resume` should not perform implicit OCI rebuilds in v0. Hidden network
  and ext4 toolchain dependencies make restore less predictable than an
  explicit preload or bundle step.
- The manifest must bind the rootfs artifact to the actual virtio-blk
  transport slot and validate it against captured device state. A generic
  `device_index` is too easy to misread as the rootfs device when console,
  net, vsock, and rng transports are also present.
- Verification must be descriptor-based to avoid cache time-of-check/time-of-use
  mistakes: open the digest-addressed artifact read-only, hash that fd, and
  pass that same fd to the backend.
- Read-only rootfs does not eliminate device-state risk. Capture still needs a
  quiescent virtio-blk queue rule before rootfs-backed resume can ship.
