---
status: active
last_reviewed: 2026-06-28
spec_refs:
  - docs/memory.md
  - docs/plans/automatic-memory.md
  - docs/spore-format.md
  - docs/fanout.md
  - SECURITY.md
  - src/resume.zig
  - src/fanout.zig
  - src/spore.zig
related_plans:
  - docs/memory.md
  - docs/plans/automatic-memory.md
  - docs/filesystem.md
  - docs/fanout.md
---

# Automatic Local RAM Backing

## Summary

SporeVM should make local same-host RAM sharing automatic and fast without
asking users to choose a trust mode. Product restore paths should use the
fastest memory source that fits the local provenance rules, then fall back to
chunk-verified restore when that proof is absent or invalid.

The landed first version is deliberately small: a local proof sidecar next to
`ram.backing`, a host-local signing key file, and a resume planner that treats
the proof as an acceleration hint only. This proof says "this host produced and
still recognizes this backing file for this manifest"; it does not prove every
page still matches the manifest's chunk refs. The portable source of truth
remains the manifest's BLAKE3 chunk refs. The remaining active slice is an
opportunistic Linux fs-verity upgrade behind the same automatic planner.

## Problem

Automatic memory makes the guest-visible RAM contract large, currently 16GiB for
`--memory auto`. Restoring that from verified chunks is correct and portable, but
it is too slow for local fork/fan-out when the parent already has a sparse,
read-only `ram.backing` file that children could map privately and cheaply.

An earlier experiment proved the performance shape with an explicit
`--trust-ram-backing` resume flag and fan-out plumbing. That is the wrong product
UX: "trust" exposes an internal security distinction and asks users to make a
choice the runtime should make itself.

The implementation also has to avoid a false security claim. The file-backed
path skips chunk materialization, and the KVM/HVF backends only validate the fd's
size before mapping. Any automatic fast path must therefore be framed as local
provenance plus fallback, not as content verification of the whole backing file.

## Goals

- No user-facing `trust` flag, mode, or policy parameter.
- Product restore paths (`spore resume` and `spore run --from`) automatically
  map local `ram.backing` only when local proof validates.
- `spore fanout` gets the fast path by using normal resume behavior.
- Invalid, missing, foreign, or stale proofs fall back to chunk restore rather
  than widening the trust boundary.
- Restore source is observable immediately, so performance regressions do not
  hide behind silent fallback.
- Resume proof checks must be metadata-scale, not proportional to configured RAM.
- Forked children should share the parent backing with hard links where possible
  so large logical RAM stays cheap across forks.
- Bundles, pulls, and imported spores remain chunk-authoritative.

## Non-Goals

- No database, daemon, or registry for first-pass provenance.
- No full-file hashing of `ram.backing` in the hot resume or fan-out path.
- No portable trust claim for `ram.backing`.
- No claim that a metadata-only proof makes `ram.backing` byte-equivalent to the
  manifest's chunk refs.
- No macOS kernel-enforced page verification in the first slice.
- No change to the manifest chunk format or the portable distribution contract.
- No attempt to defend against a malicious same-UID local process that can read
  the host-local signing key and rewrite local files. The current threat model
  is untrusted guests and untrusted peers, not hostile code with the user's
  local filesystem authority.

## Target Model

Each local spore that carries a usable backing file may also carry:

```text
<spore>/
|-- manifest.json
|-- chunks/<blake3-hex>
|-- ram.backing
`-- ram.backing.proof
```

The proof is local-only metadata. It is not included in portable bundles, and it
does not change chunk verification. A first-pass proof should include:

- proof schema version;
- manifest memory fingerprint, covering `platform.ram_size`, `chunk_size`, and
  ordered memory chunk refs;
- backing kind, relative path, and logical size;
- file identity from `fstat` after opening the final backing file: regular-file
  type, device id, inode, owner uid, logical size, and modification time;
- producer metadata such as SporeVM version and backend;
- keyed MAC over the proof fields using a private host-local key file.

The first proof schema should deliberately exclude link count and ctime.
`spore fork` creates additional hard links to the same inode; link count and
ctime would make earlier proofs stale even though the backing bytes did not
change. The tradeoff is explicit: Slice 1 catches accidental mismatch and
foreign/imported backing files, but it does not defend against same-UID tampering
that can rewrite bytes and reset mtime.

The key is a single local file under the existing runtime root from
`src/local_paths.zig`: `$SPOREVM_RUNTIME_DIR/local-ram-backing.key`,
`$XDG_RUNTIME_DIR/sporevm/local-ram-backing.key`, or the existing fallback
runtime root under `TMPDIR`. The runtime root must be created or verified as
owner-only `0700`, and the key must be a regular owner-only `0600` file. If
those permissions cannot be enforced, or if the runtime key disappears after a
reboot, resume simply uses chunks.

Resume and `run --from` behavior:

1. Load and validate the manifest as today.
2. If `ram.backing` and `ram.backing.proof` exist, open both read-only without
   following symlinks where the platform supports that. The proof must be a
   regular file.
3. Validate backing metadata, memory fingerprint, and proof MAC.
4. If every check passes, pass the fd to the backend for `MAP_PRIVATE` restore.
5. Record the selected restore source as `local_backing`.
6. If any check fails, close the fd, record the fallback reason, and restore from
   verified chunks.

Capture and fork behavior:

- Capture writes `ram.backing` and then writes or refreshes the proof after the
  backing is finalized read-only.
- `spore fork` first validates the parent's local proof. When it passes and the
  filesystem supports hard links, fork hard-links `ram.backing` into each child
  and writes a child-local proof for the child's manifest.
- If hard-linking fails, fork should omit child backing metadata and let resume
  use chunks.

## Safety Model

Chunks remain restore authority. The local backing proof is a fast-path
capability for a backing file that this host created and still recognizes. When
that fast path is selected, SporeVM is intentionally relying on local provenance
and file permissions instead of re-verifying every chunk.

The proof prevents accidental or imported use of arbitrary local paths as RAM.
It is not a substitute for content verification against every memory chunk. On
Linux, a later fs-verity slice can strengthen this by storing and checking the
kernel's verity digest before mapping. On macOS, the default remains honest
about its boundary: local proof plus private file permissions are provenance,
not kernel-enforced page integrity.

## Current State

Slice 1 is implemented in the active code path: product captures write
`ram.backing.proof` when a runtime key is available, `spore fork` validates the
parent proof before hard-linking local backing into children and writing
child-local proofs, and product restore paths (`spore resume` and
`spore run --from`) automatically choose between `local_backing` and `chunks`.

The proof is validated with bounded metadata-scale work. It is opened without
following symlinks, must be a regular file, and is capped at 16KiB before JSON
parsing. It checks the manifest memory fingerprint, canonical backing metadata,
opened file identity, producer, and HMAC from the host-local runtime key. Missing
proof, corrupt proof, symlinked proof, missing or foreign key, file identity
mismatch, or manifest mismatch all fall back to verified chunks.

Distribution hygiene has also landed. Bundle pack, unpack, pull, and local
materialization paths strip `memory.backing` from distributed manifests, and
durable format docs describe `ram.backing.proof` as local acceleration metadata,
not distribution authority.

The old `kvm-boot` and `hvf-boot` explicit trust flags have been removed as
well. Backend file-backed restore is still supported, but product paths now feed
it only through proof-gated local backing selection.

The current implementation keeps the host-local proof and restore planner behind
one internal seam: `openProvenLocalMemoryBacking` and
`writeLocalMemoryBackingProof` in `src/spore.zig`. That is deliberate for the
landed slices. Product restore callers (`src/resume.zig` and `src/run.zig`) use
the planner result, while `spore.fork` still rewrites child manifests, backing
links, and child proofs in one place. Do not extract a separate local-backing
module just to move code around; before fs-verity there is only one concrete
proof path, so a split would add indirection without reducing what callers need
to know.

## Delivery Strategy

### Slice 1: Proof-Gated Automatic Local Backing

Replace the temporary explicit `--trust-ram-backing` product path with an
internal restore planner. Add proof read/write helpers, generate proofs for
fresh captures and forks, and let product restore paths automatically use a
proof-validated local backing fd. Add restore-source reporting in the same slice
so fast-path misses are visible in tests and operator output.

Status: landed.

Done when:

- product `spore resume` and `spore run --from` have no user-visible trust flag;
- product `spore fanout` no longer passes a trust flag;
- same-host fan-out still maps local backing and passes the default counter
  fan-out smoke;
- missing, corrupt, foreign-key, or mismatched proof cases fall back to chunks;
- restore output, logs, or stats distinguish `local_backing` from `chunks`, and
  the fan-out and `run --from` smokes assert the expected fast path;
- proof validation does not read the 16GiB backing file.

### Slice 2: Distribution and Lifecycle Hygiene

Status: landed.

Make the local-only boundary explicit everywhere state moves. `spore pack`,
`spore unpack`, and `spore pull` should ignore or strip proof files the same way
portable bundles strip local backing metadata. `spore --json ls` can expose the
same restore-source state once named runtime stats have a cheap source for it.

Done when:

- portable bundle materialization never installs a trusted proof from a bundle;
- local pull of a child still resumes correctly through chunks;
- docs describe proof files as local acceleration metadata, not spore format
  authority.

### Slice 3: Linux fs-verity Upgrade

Status: not started.

Add an opportunistic Linux-only verifier behind the same automatic planner. When
the filesystem supports fs-verity, enable it after finalizing `ram.backing`,
store the verity digest in the proof, and verify the digest before mapping.
This should deepen the existing planner seam rather than introduce a
user-facing mode. If the code is split before or during this slice, split around
the planner contract after the `spore.fork` coupling is addressed, not around a
new wrapper with one implementation.

Done when:

- unsupported filesystems continue to use the Slice 1 proof path or chunks;
- enabling fs-verity is benchmarked separately from resume/fan-out;
- the user-facing CLI remains unchanged.

## Verification

- Unit tests for memory fingerprinting, proof MAC validation, bad proof fallback,
  wrong manifest fallback, foreign-key fallback, and symlinked proof fallback.
- Fork tests that children get hard-linked backing plus child-local proof, or no
  backing metadata when hard-linking is unavailable.
- Tests that proof validation ignores link count and ctime but rejects wrong
  inode, owner, size, memory fingerprint, or MAC.
- Product smokes:
  - `mise run check`
  - `scripts/smoke-counter-fanout.sh`
  - a local resume proving fallback still works after deleting or corrupting
    `ram.backing.proof`
- Performance check: default 16GiB fan-out should keep first child output and
  identity lines in the same range as the explicit local-backing experiment, and
  proof validation should be visible as metadata-scale work only.

Validation on 2026-06-20:

- `mise run check` passed.
- `mise exec -- zig build -Dtarget=aarch64-linux` passed, covering the Linux
  `statx` proof identity branch.
- `SPORE_SMOKE_FANOUT_COUNT=3 scripts/smoke-counter-fanout.sh` passed on HVF.
- `scripts/smoke-run-capture.sh` passed on HVF and asserts `spore run --from`
  logs `source=local_backing reason=proof_valid`.
- A direct product debug resume of a forked 16GiB child logged
  `source=local_backing reason=proof_valid` and backend
  `mode=local_backing ... memory_ms=0`.
- Deleting the same child's `ram.backing.proof` before product resume logged
  `source=chunks reason=proof_unavailable` and backend
  `mode=eager_chunks`.

## Key Learnings From Pressure-Testing

- The public `trust` flag is the wrong abstraction. The runtime has enough
  context to make the fast-path decision automatically and safely fall back.
- A database would add lifecycle and cleanup complexity without changing the
  core proof. A sidecar plus host-local key keeps provenance next to the file it
  describes.
- Hashing all of `ram.backing` on resume would recreate the scaling bug that
  automatic memory was meant to avoid. The first slice proves local provenance,
  not RAM byte integrity.
- Silent fallback would hide the exact regression this work is trying to fix.
  Restore source reporting belongs in the first implementation slice, not later
  polish.
- Hardlink identity is not an implementation detail. The proof schema must avoid
  link count and ctime so creating siblings does not invalidate earlier proofs.
- fs-verity is valuable but should not block the default UX. It is a stronger
  Linux implementation of the same local-proof contract, not a user-facing mode.

## Resolved Decisions

- No user-facing trust mode.
- No database in the first design.
- Failed local proof falls back to verified chunks.
- Local proof is acceleration metadata, not portable restore authority.
- Slice 1 proves local provenance only; it does not claim page-integrity
  equivalence with chunk verification.
- Proof file identity includes regular-file type, device id, inode, owner uid,
  logical size, and modification time. It excludes link count and ctime so
  hard-linked fork children remain valid.
- The host-local key lives under the existing SporeVM runtime root, must be
  protected by owner-only `0700` root and `0600` file permissions, and is allowed
  to be ephemeral. Lost keys invalidate proofs and force chunk fallback.
- Restore-source observability is part of Slice 1.
- The first slice replaced the explicit fan-out trust plumbing before that UX
  shipped.

## Open Questions

No blocking questions for the landed slices. Slice 3 needs Linux filesystem
support and benchmark evidence before it is worth implementing.
