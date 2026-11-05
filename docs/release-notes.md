# Release Notes

## Unreleased

### Lazy images from a store

`spore image push local/app:1 /srv/images/app` writes a static image store
that any file server can publish, and `spore run --image
https://images.example/app` (or `create`) boots it with only the image's
manifest, config and index local, fetching each rootfs object the guest reads
on first use. `--save`, `--commit` and `spore save` are refused for images run
from a store. See `docs/image-format.md`.

### Format reset

Old local formats have no readers. `spore host-info` reports only
`spore.host-info.v3`, including on arm64. A named VM whose spec still has the
removed memory `policy`, or a writable disk with the removed `layers` field
from an earlier build, is stale; `spore vm rm` stops its monitor if it is still
running and removes it. `cache gc` deletes step records from every older
builder version (`sporevm-build-v0` to `v8`) instead of keeping them as roots.
GC treated v0 to v5 records as unknown and kept every CAS entry, so on a cache
that holds them the first GC now runs a real sweep. JSON output advances to
`spore.cache.gc.result.v2` without `legacy_step_record_count` or
`unparseable_ref_count`.

`spore-disk-index-v2` is the only disk-index encoding, and the manifest memory
index now uses it too, so manifest bytes change. Older disk indexes fail as too
old, and manifests with an older memory index are rejected. `cache gc` keeps an
old disk index that an image or record still names but reclaims the objects
only it referenced.

Spore manifests are version 7, one shape for any vCPU count and fixed or
elastic memory: `platform` always records `vcpu_count` and `gic_redist_stride`,
and `machine` holds either `single` or `multi` state. Manifests from versions 0
to 6 fail with `FormatTooOld`, so saved spores, checkpoints and bundles from
earlier builds must be re-created. The always-empty `disk.layers` field is
gone, and every manifest save is validated.

The guest agent speaks only the SPIO exec protocol and parses every request
strictly; the text exec protocol and the `start`, `attach` and `generation`
requests are gone.
Saved RAM carries the agent that was running, so version 6 manifests, whose
agent still answers the text protocol, are too old as well.

Saved-spore pins are `spore.saved-disk-pin.v3`: the pin id, the disk storage
it roots and, until the save is durable, its pending publication. A pin no
longer records the manifest hash, so editing a pinned save's manifest no longer
stops it restoring. Pin records from earlier builds (v1 and v2) fail as too
old, root nothing, and `cache gc` deletes them as `saved-spore-stale-pin`
entries; as with manifests, saves from earlier builds must be re-created.
Before, GC kept v1 pins and their storage even after the save was removed.

### One ext4 writer

The native ext4 writer now maps files through triple-indirect blocks, so image
rootfs builds no longer fail on files larger than 4 GiB. The e2fsprogs writer
(`SPOREVM_EXT4_WRITER=external`), the `--mkfs` and `--debugfs` options of
`spore build` and `spore rootfs`, and the macOS case-sensitive sparse-image
staging volume are removed. Rootfs cache entries written by the e2fsprogs
writer are rebuilt with the native writer.

### One local image catalog

Pulled, imported, built, committed, and unpacked images share one catalog
keyed by native BLAKE3 image identity, with durable record writes. Bumping the
rootfs builder no longer orphans local refs. Older flat cache entries
(`<cache>/<key>.ext4` and `<key>.json`, `refs/local/`) are no longer read;
delete the rootfs cache directory to reclaim their space.
`spore.rootfs.import.result.v2` drops `rootfs_path` and reports the image
identity as `image_manifest_digest`. `spore run --rootfs` no longer trusts
files in the rootfs cache without hashing them.

### Embedding libraries removed

The C ABI (`spore.h` and the `libspore` archives), the Go binding, and the Zig
`libspore` module are removed; the CLI's `--json` output is the only interface.

### Checkpoint removal leaves pin release to GC

`spore checkpoint rm DIR` now deletes a checkpoint whose manifest parses,
refusing while a foreground or named restore holds a lazy-disk lease on it. It
no longer verifies disk objects, so checkpoints with corrupt storage can be
removed. `spore cache gc --force` releases the pin and storage. The removal
journal is gone, and JSON output advances to `spore.saved.remove.result.v2`
without `ownership`, `pin_id`, or `pin_removed`.

### Bundles are always indexed

`spore pack` without `--children` now always writes `bundle.json` with no
children. Memory-only spores and spores with an exact-bytes rootfs but no
`rootfs.storage` used to get a flat bundle, so their layout and `bundle_digest`
change. Spores with chunked rootfs storage and `--rootfs=metadata-only` packs
were already indexed and are byte-identical. Flat bundles from earlier versions
fail with `FormatTooOld` and must be re-packed. `spore inspect-bundle` no longer
reports `indexed`.

### Experimental AMD64 fresh workloads

Linux/AMD64 KVM fresh workloads now use native `linux/amd64` OCI selection,
explicit rootfs inputs, the shared writable rootfs and image-commit path, and
the shared network policy graph. Native acceptance covers rootfs execution and
mutation, image commit, DNS, HTTP, hard-floor deny policy, bound services, and
host-to-guest forwarding. Native `spore build` now selects `linux/amd64`,
including automatic `TARGETARCH=amd64` build arguments.

The profile remains experimental, source-built, fixed at one vCPU and 512 MiB,
and fresh-only. Capture, save, restore, resume, disk fork, fan-out, multi-vCPU,
and elastic memory remain fail closed; no AMD64 saved-state format or release
archive is introduced.

### Explicit initial and maximum memory

Memory is fixed at 512 MiB by default. `--memory SIZE` now always selects the
initial guest-visible size and is fixed unless `--max-memory SIZE` supplies a
larger grow-only virtio-mem ceiling. `--max-memory` may be used alone with the
512 MiB initial default. The former `--memory auto` policy has been removed;
use `--memory 512mb --max-memory 16gb` to preserve its intended elastic range.

JSON results use the same two-size contract. Existing `memory_bytes` fields now
unambiguously mean initial memory, and the additive maximum field enables
elasticity. Named list output advances to `spore.lifecycle.list.result.v2`,
where memory contains `initial_bytes` and `maximum_bytes`.

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
remain reserved for saved spores. `spore image pack` also accepts tags from
`spore rootfs import-oci` or `import-tar` (SHA-256 local digests).
`spore --json image pack` and
`spore --json image unpack` now print their documented result documents
instead of text.

### Image gateway pull removed

`spore image pull` (experimental since v0.15) is removed.

### fs-verity RAM backing proofs removed

Local RAM backing proofs no longer enable or record Linux fs-verity; existing
schema v2 proofs are ignored and those spores restore from verified chunks.

## v0.17.1

### Managed kernel security update

New managed-kernel selections on ARM64 and x86_64 use Linux 6.1.191 from
`sporevm/kernels` release `v0.7.1`, replacing Linux 6.1.155. The approved x86
image digest advances with the release; verification remains fail closed.
Running VMs and saved spores retain their existing kernels. Create fresh VMs
with the updated defaults to use the new kernel.

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
