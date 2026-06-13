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
| Guest memory access during dirty scans | guest | required at slice 7 |
| Spore manifest decode | registry, disk | fuzzed; unknown versions and malformed manifests fail closed |
| Chunk decode (zstd) and CAS reads | peers, registry, disk | required at slice 5 |
| Generation device inputs | guest | MMIO register surface fuzzed; fork params schema required at slice 6 |
| Control socket JSON | local consumers | required at slice 3 |

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
