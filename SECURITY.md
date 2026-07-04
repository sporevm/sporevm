# Security Posture

SporeVM is an isolation boundary written in Zig, which is not memory-safe.
That is a deliberate tradeoff, bought back structurally. This document is a
founding constraint, not a retrofit: it must be updated in the same change
that alters the attack surface.

## Threat Model

An untrusted guest must not escape the VMM. The current threat model is self-hosted
CI and agent isolation: hostile code runs inside the guest, and chunk data may
arrive from untrusted peers. We do not claim hardened multi-tenant public
cloud isolation.

Secrets never enter the VMM process or the spore format. Credential mediation
belongs to consumers (for example cleanroom's host gateway).

Local caches (rootfs cache, kernel cache, distribution chunk cache) live in
the same host trust domain as the `spore` binary itself: a principal who can
write to them can also replace the binary or kernel image. Cache integrity is
therefore enforced where bytes enter a cache — every install verifies content
against the expected digest before publishing it read-only — and product open
paths trust installed entries without re-hashing them. Structural checks
(no symlinks, regular file, exact size) still apply at open time and fail
closed. This verify-at-install, trust-at-open contract assumes a per-user
cache on a single-tenant host; a shared or multi-tenant cache would need
open-time verification and is out of scope today.

## Attack Surface

Every path that parses attacker-influenced data is enumerated here and carries
fuzz targets from the slice that introduces it:

| Surface | Input source | Status |
|---|---|---|
| Virtqueue descriptors, rings, and device request headers | guest memory | shared queue/MMIO paths and current console/blk/vsock/rng device paths fuzzed; virtio-net TX/RX frame-boundary handling, short virtio-net headers, oversized frames, queue exhaustion, reset, shutdown paths, and the grow-only virtio-mem request parser are fuzz/unit covered; vsock receive delivery splits stream packets to fit guest-posted buffer chains and never truncates, honors the guest's advertised credit window before sending, volunteers credit updates while consuming guest stream data, and resets abandoned or unknown stream connections; guest-controlled receive descriptor layouts driving the split path are fuzz covered; new device parsers require fuzz targets in the same slice |
| `spore-netd` frame stream, ARP, IPv4/UDP/TCP, DNS, and policy parsers | guest-originated Ethernet frames via virtio-net | length-prefixed frame bounds, ARP reply handling, IPv4/UDP DNS dispatch, DNS name parsing, malformed DNS handling, bound-service `*.spore.internal` answers, TCP frame classification, hard-floor policy, CIDR allow rules, DNS-learned host allow rules, and DNS-rebinding hard-floor precedence are unit and fuzz covered. Explicit bound services proxy guest-controlled TCP bytes to declared host Unix stream sockets, so service providers must treat bound sockets as guest-exposed. Named lifecycle monitors spawn the optional `spore-netd` helper before applying the monitor jail, then own helper shutdown with the VM |
| Guest memory access during dirty scans | guest | KVM dirty-log and HVF write-protect harness paths have landed; dirty pages plus VMM-originated virtio writes are coalesced to fixed 2MiB chunks, zero chunks are elided, and non-zero chunks are BLAKE3-addressed before being recorded in the manifest. |
| Lazy RAM fault handling | guest page faults plus spore CAS chunks | KVM userfaultfd and HVF abort-exit paths are opt-in; faults materialize whole verified chunks and fail closed on malformed manifests or chunk mismatches |
| Spore manifest decode | registry, disk | manifest v0 and v1 parsing/validation fuzzed; unknown versions and malformed manifests fail closed |
| CAS chunk reads | peers, registry, disk | BLAKE3 verified before restore; malformed memory manifests are fuzzed; compression is unsupported |
| Local RAM backing proof sidecar | local disk | Product restore paths open `ram.backing.proof` without following symlinks, require a regular file, and read at most 16KiB; malformed JSON, missing keys, foreign keys, stale file identity, memory fingerprint mismatch, and bad MAC fall back to verified chunks. Schema v2 proofs may carry signed Linux fs-verity SHA-256 metadata; restore re-measures the opened fd and falls back to chunks if the kernel digest is unavailable or mismatched. Without verity metadata, the proof remains host-local provenance for a `MAP_PRIVATE` fd, not portable byte-integrity authority |
| Bundle metadata, chunkpack index, pack segments, and pull/push URIs | peers, registry, disk, S3, HTTP(S) | `bundle.json`, `rootfs.index.json`, and chunkpack index parsing are fuzzed; unpack/pull only accept canonical metadata paths, canonical child ids, canonical pack paths, verified rootfs artifact paths, descriptor-derived rootfs CAS index/object paths, manifest-derived disk layer/object paths, absolute undecoded `file://` pull sources, and digest-pinned `s3://...@sha256:<bundle>` or `http(s)://...@sha256:<bundle>` pull sources. S3 and HTTP(S) pull download only the canonical files named by validated metadata, verify the canonical bundle digest before materialization, then verify segment SHA256 plus logical BLAKE3 chunk IDs, rootfs CAS index/object digests, and BLAKE3 disk objects before writing chunks or attaching writable disk layers. HTTP(S) redirects, mutable query strings, fragments, userinfo, percent-encoded paths, and path traversal are rejected |
| Node-local distribution chunk cache | local disk | `spore pull` stores memory chunks by BLAKE3 id only after verifying source bytes, re-verifies cache hits before hard-linking or copying them into a materialized spore, and fails closed on corrupt, non-file, or symlinked cache entries |
| Immutable rootfs artifact resolution | manifest, local rootfs cache, bundle rootfs artifacts | product resume only accepts the immutable ext4 rootfs kind, validates virtio-blk binding, and opens the digest-addressed cache entry read-only under the verify-at-install, trust-at-open cache contract: the open refuses symlinked or non-regular entries and size mismatches without re-hashing installed bytes. Every install into the digest cache verifies content against the manifest digest and size before atomically publishing the entry read-only; user-supplied rootfs paths are always copied (never hardlinked) into the cache so later edits cannot alias cache entries; bundle unpack verifies exact rootfs bytes by manifest digest and size before installing them; metadata-only rootfs bundle policy is accepted only with an explicit materialization flag and a fully BLAKE3-verified digest-cache hit |
| Manifest-bound chunked rootfs storage descriptor and block index | manifest, registry, disk, bundle, peers | `rootfs.storage` is parsed as a separate storage/artifact authority from OCI provenance, requires `chunked-ext4-rootfs-v0`, BLAKE3, exact `rootfs/blake3` namespace, matching rootfs device binding, logical size matching the ext4 artifact size, and `base_identity == index_digest`; `rootfs-block-index-v0` bytes are BLAKE3-checked against the descriptor before parse, fuzzed, and rejected on unknown index kind, non-canonical ordering, duplicate or out-of-range chunks, implicit or overlapping zero-fill, descriptor mismatches, unsupported namespace, or malformed digests; the flat digest-addressed ext4 artifact is the only runtime read path: bundle unpack/pull assemble it from BLAKE3-verified local chunk objects at materialization time, product resume repeats that assembly once when the flat entry is missing or corrupt, and assembly hashes the result and requires it to equal the manifest artifact digest before atomic publication, so an inconsistent artifact/index pairing fails closed instead of poisoning the digest cache; bundle unpack/pull install descriptor-bound indexes and chunks into the rootfs CAS cache through symlink-safe, verify-before-publish cache writes, and fail closed on missing or corrupt index/chunk bytes before guest use |
| Writable disk layer indexes and disk objects | registry, disk | `disk-layer-v0` indexes are JSON parsed and fuzzed; layer index bytes are verified by BLAKE3 ref before parse; disk objects are verified by BLAKE3 before reads; extents and explicit zero clusters are canonical sorted, unique, and range-checked; corrupt or missing objects fail before use |
| `spore run` legacy and SPIO frames | guest vsock stream | bounded host buffers; legacy exit/timing string parser is unit and fuzz covered; SPIO v1 frame headers, stream ids, payload lengths, flags, per-stream offsets, terminal output frames, and resize payloads are unit covered; malformed frames fail the run. `start-v1` and `attach-v1` setup requests fail closed on unsupported stdio modes, and input attach validates the captured guest session had an interactive stdin pipe or PTY before accepting host bytes. TTY mode exposes a guest PTY to the child process and treats merged terminal bytes as untrusted guest output |
| `spore run --inject` files | caller-provided local files | host validates flat injected file ids and regular non-symlink source files, appends bytes to the existing initrd as `newc` entries, and the initrd agent copies only flat regular files into `/run/sporevm/injected` tmpfs before exec. The bytes are not rootfs cache inputs, and injection is rejected with `--capture` and `--from` to avoid ambiguous persistence |
| OCI manifest, OCI layout, and layer decode | registry, local OCI layout | rootfs builder only, outside the monitor process; mutable tags are resolved into digest-pinned refs before build materialization, local refs resolve to digest-pinned local identities, blobs are verified, layout tar extraction and layer tar application are path-safe, PAX xattr handling is bounded and limited to deliberately supported capability records, and JSON/tar fuzz targets cover parser inputs |
| Generation device inputs | guest | MMIO register surface and fork/resume params schema are fuzz/unit covered |
| Control socket JSON and named exec/copy SPIO stream | local consumers | local-only lifecycle monitor protocol is implemented for HVF and KVM, including fixed-RAM multi-vCPU create, exec, file copy, suspend, and named resume; named startup waits for the socket to answer a `hello` request carrying the `spore.monitor.hello.v1` schema, an exact SporeVM version match, and the monitor helper contract before create, resume, or fork-child startup reports success, and control operations other than shutdown re-verify the same handshake; interactive named exec and named file copy use streaming control requests plus the same bounded SPIO frame parser for stdin, terminal input, resize, terminal output, and exit; copy requests accept explicit regular files or directory trees, reject non-absolute guest paths plus `.`/`..` components, reject symlinks and special files, publish copy-in through no-overwrite temp paths, and create copy-out host destinations with no-overwrite flags; monitor processes deny child process execution through an embedded macOS sandbox profile or Linux seccomp filter; malformed requests fail closed and the socket is protected by private runtime-directory permissions |
| Named create options JSON | local callers, toolchains | `spore create --options @file.json` is bounded to the lifecycle metadata size limit, parsed into the same create option validators as CLI flags, rejects unknown schema versions and mixed file/field configuration, and is fuzz covered |

## Structural Rules

- **ReleaseSafe only for shipping builds.** ReleaseFast is for benchmarks.
  `build.zig` prefers ReleaseSafe; release packaging must never override it.
- **Chunks are verified before use.** Any chunk received from any source is
  checked against its BLAKE3 id before being mapped into guest memory or
  parsed. A malicious peer can deny service, never inject state.
- **Fail closed.** Unknown manifest versions, unsatisfiable platform
  contracts, and unverifiable chunks are errors, never degraded behavior.
- **The stable monitor scope is local named lifecycle.** `spore create`,
  `spore exec`, `spore suspend`, `spore resume --name`, `spore ls`, and
  `spore rm` are available on supported backends, with fixed-RAM multi-vCPU
  create, exec, explicit file/directory copy, suspend, and named resume. Monitor processes deny child process
  execution through an embedded macOS sandbox profile or Linux seccomp filter
  after optional startup helpers are spawned, covered by
  `mise run smoke:monitor-jail`. Startup fails closed unless the local control
  socket answers the same-version monitor handshake. Disk-backed named checkpointing preserves
  immutable-rootfs identity and sealed writable disk layers; image-created VMs
  use chunked rootfs storage, and explicit `--rootfs PATH` VMs use exact rootfs
  artifacts.
- **The device model stays minimal.** Every device addition expands both the
  attack surface and the portability contract, and requires updating
  `docs/spore-format.md`, this document, and the relevant durable design doc.
- **Fuzzing runs continuously in CI**, not as a one-off audit.

## Reporting

This repository is currently private. Report issues directly to the
maintainers. A public disclosure policy lands with the public release.
