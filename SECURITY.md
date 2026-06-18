# Security Posture

SporeVM is an isolation boundary written in Zig, which is not memory-safe.
That is a deliberate tradeoff, bought back structurally. This document is a
founding constraint, not a retrofit: it must be updated in the same change
that alters the attack surface.

## Threat Model

An untrusted guest must not escape the VMM. The v0 threat model is self-hosted
CI and agent isolation: hostile code runs inside the guest, and chunk data may
arrive from untrusted peers. We do not claim hardened multi-tenant public
cloud isolation.

Secrets never enter the VMM process or the spore format. Credential mediation
belongs to consumers (for example cleanroom's host gateway).

## Attack Surface

Every path that parses attacker-influenced data is enumerated here and carries
fuzz targets from the slice that introduces it:

| Surface | Input source | Status |
|---|---|---|
| Virtqueue descriptors, rings, and device request headers | guest memory | shared queue/MMIO paths and current console/blk/net/vsock/rng device paths fuzzed; new device parsers require fuzz targets in the same slice |
| Guest memory access during dirty scans | guest | KVM dirty-log and HVF write-protect harness paths have landed; dirty pages plus VMM-originated virtio writes are coalesced to fixed 2MiB chunks, zero chunks are elided, and non-zero chunks are BLAKE3-addressed before being recorded in the manifest. |
| Lazy RAM fault handling | guest page faults plus spore CAS chunks | KVM userfaultfd and HVF abort-exit paths are opt-in; faults materialize whole verified chunks and fail closed on malformed manifests or chunk mismatches |
| Spore manifest decode | registry, disk | fuzzed; unknown versions and malformed manifests fail closed |
| CAS chunk reads | peers, registry, disk | BLAKE3 verified before restore; malformed memory manifests are fuzzed; compression is not in v0 |
| Bundle metadata, chunkpack index, pack segments, and pull/push URIs | peers, registry, disk, S3, HTTP(S) | `bundle.json`, `rootfs.index.json`, and chunkpack index parsing are fuzzed; unpack/pull only accept canonical metadata paths, canonical child ids, canonical pack paths, verified rootfs artifact paths, absolute undecoded `file://` pull sources, and digest-pinned `s3://...@sha256:<bundle>` or `http(s)://...@sha256:<bundle>` pull sources. S3 and HTTP(S) pull download only the canonical files named by validated metadata, verify the canonical bundle digest before materialization, then verify segment SHA256 plus logical BLAKE3 chunk IDs before writing chunks. HTTP(S) redirects, mutable query strings, fragments, userinfo, percent-encoded paths, and path traversal are rejected |
| Node-local distribution chunk cache | local disk | `spore pull` stores memory chunks by BLAKE3 id only after verifying source bytes, re-verifies cache hits before hard-linking or copying them into a materialized spore, and fails closed on corrupt, non-file, or symlinked cache entries |
| Immutable rootfs artifact resolution | manifest, local rootfs cache, bundle rootfs artifacts | product resume only accepts the immutable ext4 rootfs kind, validates virtio-blk binding, opens the digest-addressed cache entry read-only, verifies that same fd by BLAKE3 and size, and rejects missing, non-file, or mismatched artifacts before VM creation; bundle unpack verifies exact rootfs bytes by manifest digest and size before atomically installing them into the digest cache; metadata-only rootfs bundle policy is accepted only with an explicit materialization flag and a verified digest-cache hit |
| `spore run` exit frames | guest vsock stream | bounded host buffer; exit/timing string parser is unit and fuzz covered; malformed frames fail the run |
| OCI manifest, OCI layout, and layer decode | registry, local OCI layout | rootfs builder only, outside the monitor process; mutable tags are resolved into digest-pinned refs before build materialization, local refs resolve to digest-pinned local identities, blobs are verified, layout tar extraction and layer tar application are path-safe, and JSON/tar fuzz targets cover parser inputs |
| Generation device inputs | guest | MMIO register surface and fork/resume params schema are fuzz/unit covered |
| Control socket JSON | local consumers | local-only lifecycle monitor protocol is implemented for HVF; malformed requests fail closed and the socket is protected by private runtime-directory permissions |

## Structural Rules

- **ReleaseSafe only for shipping builds.** ReleaseFast is for benchmarks.
  `build.zig` prefers ReleaseSafe; release packaging must never override it.
- **Chunks are verified before use.** Any chunk received from any source is
  checked against its BLAKE3 id before being mapped into guest memory or
  parsed. A malicious peer can deny service, never inject state.
- **Fail closed.** Unknown manifest versions, unsatisfiable platform
  contracts, and unverifiable chunks are errors, never degraded behavior.
- **The monitor process is jailed** before the first release: seccomp
  allowlist on Linux, sandbox profile and minimal entitlements on macOS.
  Jail profiles are tested by attempting denied operations.
- **The device model stays minimal.** Every device addition expands both the
  attack surface and the portability contract, and requires editing
  docs/plans/foundation.md.
- **Fuzzing runs continuously in CI**, not as a one-off audit.

## Reporting

This repository is currently private. Report issues directly to the
maintainers. A public disclosure policy lands with the public release.
