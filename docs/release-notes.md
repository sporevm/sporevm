# Release Notes

## Unreleased

### Explicit initial and maximum memory

Memory is fixed at 512 MiB by default. `--memory SIZE` now always selects the
initial guest-visible size and is fixed unless `--max-memory SIZE` supplies a
larger grow-only virtio-mem ceiling. `--max-memory` may be used alone with the
512 MiB initial default. The former `--memory auto` policy has been removed;
use `--memory 512mb --max-memory 16gb` to preserve its intended elastic range.

The Zig, C, and Go APIs use the same two-size contract. Existing
`memory_bytes`/`MemoryBytes` fields now unambiguously mean initial memory, and
the additive maximum field enables elasticity. The C ABI advances to 20 and
`SporeCreateNamedOptions` advances to version 7. Named list output advances to
`spore.lifecycle.list.result.v2`, where memory contains `initial_bytes` and
`maximum_bytes`.

Elastic captures use manifest v4 and persist backend-neutral initial, maximum,
requested, captured, and exact plugged-block state. Current readers retain v2
and v3 compatibility by treating their `ram_size` as fixed initial, maximum,
requested, and captured memory; old readers reject the new elastic version.

### Immutable native image archives

`spore image pack` now turns a complete local native image into one immutable
gzip archive for CI or object-store publication. `spore image unpack` requires
the archive SHA-256, expected native image BLAKE3, and platform, verifies the
canonical native image closure and every BLAKE3 rootfs object, and publishes an
ordinary local ref only after
the complete image is installed. The archive carries no suspended machine
state; existing top-level bundle `pack`, `push`, `pull`, and `unpack` commands
remain reserved for saved spores.

## v0.15.0

SporeVM v0.15.0 adds an experimental Linux/AMD64 KVM fresh-execution
profile and the first interoperable image-gateway contracts and eager pull
client. The existing macOS/ARM64 HVF and Linux/ARM64 KVM lifecycle remains the
mature product path; AMD64 is a deliberately narrow, source-built preview.

### Experimental Linux/AMD64 KVM execution

Linux/AMD64 hosts can now run fresh one-shot VMs and use fresh named
`create`/`exec`/`rm` through the managed kernel and embedded minimal exec
initrd. The profile has a frozen x86-64 board, an approved same-host CPU
profile, bounded bzImage planning, and native KVM acceptance coverage.

The profile requires one vCPU and exactly 512 MiB of memory. Image and rootfs
execution, networking, build, capture, save, restore, resume, fork, fan-out,
and standalone libspore execution remain unavailable and fail closed. AMD64
must be built from source; this release does not add an AMD64 archive.

### Verified image-gateway pulls

The new `spore image pull` command fetches one explicitly selected platform
from a repository-bound gateway source into an ordinary local image ref. It
verifies the canonical manifest, config, rootfs index, native image identity,
and every BLAKE3 object before publishing through the existing local CAS
transaction. HTTPS is required except for an explicit literal-loopback fixture
mode.

The protocol now defines canonical multi-platform indexes, platform-specific
image manifests, and typed attachment records for signatures, SBOMs,
attestations, vulnerability reports, and policy results. Gateway content may
describe `linux/arm64` or `linux/amd64`, but the experimental AMD64 runtime
cannot yet execute image or rootfs content.

This is an eager client and data-contract release, not a production gateway
service. Authentication, conversion admission, batch transfer, lazy remote
reads, attachment publication, and policy evaluation remain future work.

### Retained named-create output

`spore create` now retains bounded stdout and stderr from its initial command
by default and reports where to retrieve them. `spore logs NAME` returns the
current output, process status, exit code, and truncation state after create has
returned; `--initial-output discard` keeps output intentionally ephemeral.
Automation and library callers receive the same data through an optional
`initial_command` object in `spore.lifecycle.v1`.

### Compact disk indexes

New rootfs and writable snapshots use the canonical `spore-disk-index-v2`
format. It packs contiguous BLAKE3 chunk digests and known-zero coverage into
ranges, removing the former roughly 30.62 GiB dense-disk cliff caused by one
JSON object per 64 KiB chunk. Index inputs remain capped at 64 MiB and retain
descriptor, arithmetic, exact-coverage, canonical-byte, and BLAKE3 validation.
Existing v1 indexes remain readable and keep their original content identity;
they migrate naturally when a later snapshot or commit publishes v2.

### Architecture and API compatibility

- Product-facing architecture values now use OCI names consistently:
  `arm64` and `amd64`. Direct registry pulls, local OCI-layout imports, and the
  gateway share one platform-selection authority and reject ambiguous variant
  matches.
- Architecture-discriminated host facts use `spore.host-info.v3`. The
  ARM-shaped `spore.host-info.v2` surface remains available for compatibility,
  and returns unsupported architecture on AMD64.
- The public C ABI advances to 19. Version 16 added
  `spore_host_info_json_v3`, version 17 added initial argv for named create, and
  version 18 added `spore_context_last_error_json` plus explicit streaming
  completion outcomes, and version 19 adds bounded initial-command output
  disposition and retrieval for named create. Callers should compare runtime build info with
  `SPORE_ABI_VERSION` before using the new symbol.
- Saved-state manifests remain AArch64-only and retain the existing
  `aarch64` / `sporevm-aarch64-v0` format identifiers. This release does not
  change existing AArch64 manifest bytes or device-format versions.
- Published archives remain `spore_Darwin_arm64`, `spore_Linux_arm64`, and
  their matching libspore archives.

### Build cache maintenance

`spore system df --rootfs` now includes the sparse build cache-mount aggregate
and abandoned emit temps with separate logical and allocated byte counts.
Default system prune and root-aware cache GC can reclaim that storage, report it
separately, and serialize cleanup with active builds so a mounted cache disk is
never unlinked. Builder crashes cannot leave a durable lease: the kernel drops
the process-bound locks, and later cleanup or cache validation scavenges stale
temps and recovers an unclean aggregate.

### Automation contract

Bounded CLI operations now return schema-versioned results under global
`--json`, including build, rootfs, image, version, and named copy operations.
Run, attach, restore, exec, and fanout use one
`spore.automation.event.v1` JSONL envelope and finish with an explicit
completed, failed, or canceled completion record. Stable failures carry a
code, resource scope, and three-way retry classification consistently across
CLI, Zig, C, and Go adapters. See [Automation contract](automation.md).

### Lifecycle resource vocabulary

Inspection now reports checkpoint capabilities, session streams, portability,
ownership, and an explicit resource type. `runFromSpore` always starts a new
process and rejects an empty command; embedders use the separate `attachSpore`
operation to reconnect to a saved session.

The CLI adds `spore vm rm`, `spore vm fork`, `spore checkpoint rm`, and
`spore checkpoint fork`. Removal output says whether it is deleting live
runtime state or a checkpoint and explains the backing-ownership consequence.
Image gateway, image archive, clone, and other lifecycle JSON results identify
their resource type while retaining their existing schema names where one
already existed.
The older top-level `rm` and `fork` forms remain compatible throughout the 0.x
release line.

**Full changelog:**
[v0.14.0...v0.15.0](https://github.com/sporevm/sporevm/compare/v0.14.0...v0.15.0)
