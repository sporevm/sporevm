# Release Notes

## Unreleased

### `spore push` and `spore pull` move spores through image stores

`spore push SPORE STORE/TAG` now writes a saved spore to a directory or S3
image store: its RAM chunks and disk objects go in the store's shared
`objects/`, so a spore pushed to a store holding its image uploads only its
RAM, changed disk chunks, disk index and manifest. It prints the
digest-pinned ref, and `--json` prints `spore.push.result.v2`.
`spore pull STORE/TAG --out DIR` fetches it back from a directory, HTTP(S) or
S3 store, verifying every object, and writes a save pinned in the rootfs
cache; `--json` prints `spore.pull.result.v2`. Bundles no longer travel:
pushing a bundle to S3 (`spore push BUNDLE s3://... [--region]`) and pulling
one (`spore pull file://|s3://|http(s)://... [--child] [--region]
[--allow-metadata-only-rootfs]`) are gone. To run one child of a fork batch
elsewhere, push the parent, pull it there and pass the child's identity to
`spore run --from DIR --generation FILE`.

### Performance

- On aarch64 each virtio-blk disk serves its requests on a thread of its own
  instead of on the vCPU that issued them. A slow read, such as the first read
  of an object fetched from an image store, now stalls only that disk: the
  vCPUs keep running, and the console, network, other disks and `spore exec`
  keep working.
- Restores from memory chunks read each chunk straight into guest RAM instead
  of through a heap buffer, taking another 28 to 43 percent off loads with a
  warm page cache and 10 to 35 percent with a cold one.

### Fixes

- Single-vCPU saves also wait until the vCPU is not in an interrupt handler,
  or fail with `InterruptStillActive`, as multi-vCPU saves do.

### Security

- The guest agent reads generation params (from `--generation` files, forks
  and restores) in one pass over the JSON object instead of searching the
  text for each key, so a nested object or a look-alike key can't supply a
  member's value. Params that aren't valid JSON, or that repeat a member the
  agent reads, give it the wrong type, or set a VM id, fork batch id,
  hostname or entropy seed over 127 bytes or containing NUL, now fail instead
  of being partly applied. `spore run --from`, `spore attach` and
  `spore restore` check a `--generation` file against the same rules before
  the VM starts.

### Other changes

- Saved network spores record `default_action: "deny"` for every restricted
  egress policy, including `--allow-cidr` and `--allow-host` alone; a policy
  with allow entries but no `default_action` still restores as restricted.

## v0.18.0

### Upgrading

v0.18.0 resets SporeVM's local formats and reads nothing older.

- Re-create saved spores, checkpoints and bundles from earlier versions; they
  fail with `FormatTooOld`. Spore manifests are version 7, one shape for any
  vCPU count, and disk and memory indexes are only `spore-disk-index-v2`.
- Saved RAM carries the guest agent, which now speaks only the SPIO exec
  protocol and parses every request strictly. The text protocol and its
  `start`, `attach` and `generation` requests are gone.
- Saved-spore pins are `spore.saved-disk-pin.v3`. Older pins root nothing;
  `spore cache pins` lists them as `stale` and `spore cache gc` deletes them.
- Local RAM backing proofs are v3, without fs-verity. Spores with an older
  proof restore from their verified chunks instead.
- On macOS the GICv3 redistributors moved to `0x08020000`, where KVM has them.
  HVF spores from earlier builds fail with `PlatformMismatch`.
- Stop named VMs before upgrading. A VM is live only while its monitor holds
  `vms/<name>/lock`, which older monitors don't take, so their VMs show as
  stale. `spore vm rm NAME` removes them, and any VM whose spec has removed
  fields. `spore ls` shows `starting` where it showed `incomplete`.
- Local images from earlier versions (built, committed, imported or unpacked)
  are no longer listed; build or import them again. Registry images are
  pulled again on first use.
- To reclaim space, delete the `rootfs` and `bundles` directories under the
  SporeVM cache (`~/.cache/sporevm` on Linux, `~/Library/Caches/sporevm` on
  macOS, or `SPOREVM_ROOTFS_CACHE_DIR` and `SPOREVM_BUNDLE_CACHE_DIR`).
  Otherwise the first `spore cache gc` deletes step records from older
  builders and the objects only they and old indexes kept.
- The first `spore build` after upgrading misses its cache once, because the
  guest initrd changed.
- JSON: `spore host-info` reports only `spore.host-info.v3`.
  `spore.cache.gc.result.v2` drops `legacy_step_record_count` and
  `unparseable_ref_count`. `spore.rootfs.import.result.v2` drops `rootfs_path`
  and reports the image identity as `image_manifest_digest`.
  `spore.saved.remove.result.v2` drops `ownership`, `pin_id` and
  `pin_removed`. `spore inspect-bundle` no longer reports `indexed`.

### Lazy images from a store

- `spore image push local/app:1 DEST` writes a static image store to a
  directory, or to `s3://bucket/prefix` with the aws CLI.
- `spore run --image` and `spore create --image` boot a store ref (`file://`,
  `https://` or `s3://`, by tag or `blake3:<hex>`) with only the image's
  manifest, config and index local. Each rootfs object the guest reads is
  fetched on first use, with the objects of the next 7 chunks.
- `--save`, `--save-on`, `--commit` and `spore save` first fetch the rest of
  the image, so the result needs nothing from the store.
- S3 reads are SigV4-signed with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  the optional `AWS_SESSION_TOKEN`, and `AWS_REGION` or `AWS_DEFAULT_REGION`
  from the environment only. Profiles, `~/.aws`, instance roles and pod
  identity are not read; without the variables a run fails with
  `AwsCredentialsMissing` or `AwsRegionMissing`, and with `AWS_ENDPOINT_URL`
  or `AWS_ENDPOINT_URL_S3` set it fails with `AwsEndpointUrlUnsupported`. A VM
  reads them when its disk opens and keeps them, so fetches fail once
  temporary credentials expire. Readers need `s3:GetObject`. See
  `docs/image-format.md`.

### Other changes

- `SPOREVM_DOCKER_HUB_MIRROR=mirror.gcr.io` pulls `docker.io` images through
  a mirror; refs, cache keys and digests still name `docker.io`. Registry 404
  and 429 responses fail as `RegistryNotFound` and `RegistryRateLimited`.
- Cold image pulls (`run --image`, `rootfs import-oci` and `import-tar`)
  download and merge layers without the rootfs cache lock, so other VM starts
  no longer wait for them.
- `spore build` holds the rootfs cache lock only to look up, seal and publish
  steps, so runs, saves and `cache gc` no longer wait for a long build. It now
  needs a runtime directory private to the current user.
- `spore build` rejects an invalid later stage before any stage runs, and
  pulls `COPY --from` images only after the whole Dockerfile is planned.
- Image rootfs builds handle files larger than 4 GiB.
- `spore image pack` accepts tags from `rootfs import-oci` and `import-tar`,
  and `spore --json image pack` and `image unpack` print result documents.
- `spore pack` without `--children` always writes an indexed bundle, which
  changes the `bundle_digest` of spores without chunked rootfs storage.
- `spore checkpoint rm DIR` deletes any checkpoint whose manifest parses, even
  with corrupt storage; `spore cache gc --force` releases its pin.
- `spore run`, `create` and `build` check the hypervisor before any download.
  Linux arm64 hosts without a usable `/dev/kvm` fail with `MissingKvmDevice`
  or `KvmOpenFailed`, and incompatible x86 hosts fail with
  `IncompatibleCpuProfile` and log which CPU fact differs. `spore host-info`
  reports a `/dev/kvm` that exists but can't be opened as `kvm_open_failed`.
- Remote `ADD` and registry fetches try the host's other addresses when one
  fails to connect or closes before answering.
- The shipped guest initrd is about 45% smaller; smoke-test helpers are only
  in `-Dsmoke-helpers` builds.
- `spore rootfs build` keeps its temporary files in the rootfs cache instead
  of `.zig-cache/` in the current directory.

### Performance

- Restores from memory chunks skip zero chunks: in a 512 MiB VM with 32 MiB
  in use, loading memory takes 55 ms instead of 324 ms and leaves 32 MiB
  resident instead of 512 MiB.
- Fresh x86 VMs no longer make all guest RAM resident at boot: a 512 MiB VM's
  monitor uses 46 MiB instead of 521 MiB.
- Decoding a dense 32 GiB disk index peaks at 21 MB of heap instead of 226 MB,
  and runs faster.
- Idle multi-vCPU VMs no longer poll every millisecond on the host.

### Fixes

- Saves survive a crash: full-scan RAM saves fsync each chunk, every
  `manifest.json` write is atomic, and the local RAM backing is fsynced before
  its proof. On a Linux test host a full-scan save took 50 ms longer with
  32 MiB of RAM in use and 350 ms longer with 512 MiB.
- Multi-vCPU saves wait until no vCPU is in an interrupt handler, or fail with
  `InterruptStillActive`, so restoring them on macOS no longer aborts.
- macOS release builds restore guest SIMD registers correctly, so commands
  started in a restored spore no longer fail with `exec setup failed`.
- `spore rm` stops a VM within about a second while an exec runs; the exec
  fails with `named VM is being removed`.
- `create`, `restore --name` and `vm fork` claim names atomically, and
  `vm fork` no longer undoes a `spore save` that finished while it started.
- `spore cache gc` collects unreferenced storage on hosts with local images,
  works after a destructive prune while disk-forked VMs run, and reads VM
  specs over 64 KiB.
- A named VM given an explicit deny-all policy through the embedding API no
  longer gets unrestricted egress; the CLI could not set one.
- `spore attach` fails instead of exiting 0 when the guest powers off before
  reporting its exit status.
- Networking: a slow DNS resolver no longer stalls other traffic, connects to
  denied addresses are refused at once, bytes sent after the host half-closes
  are delivered, and `spore run --bind-service ... --save` works.
- A terminal resize with a full vsock ring no longer stalls `run -t` or
  `attach`, and single-vCPU macOS snapshots no longer drop queued vsock
  packets.

### Security

- `spore copy-out` stops at 4 GiB of guest archive, applies the host umask,
  and can't be redirected by symlinks the guest swaps in. Guest output during
  a copy no longer reaches stdout, and stderr has control bytes escaped.
- x32 syscalls are killed in the monitor jail and in build `RUN` steps.
- Virtqueue rings are checked against guest RAM when a queue becomes ready and
  on restore, and ring accesses are ordered on multi-vCPU arm64.
- Manifests listing more than eight GIC redistributors are rejected instead of
  hanging validation.
- Image layers and image archives are read through one fuzzed tar parser.

### Removed

- The C ABI (`spore.h` and the `libspore` archives), the Go binding and the
  Zig `libspore` module. The CLI's `--json` output is the only interface.
- `spore image pull`, experimental since v0.15, and
  `spore image export-fixture`.
- The e2fsprogs ext4 writer, with `SPOREVM_EXT4_WRITER=external` and the
  `--mkfs` and `--debugfs` options of `spore build` and `spore rootfs`.

## v0.17.1

### Managed kernel security update

New managed-kernel selections on ARM64 and x86_64 use Linux 6.1.191 from
`sporevm/kernels` release `v0.7.1`, replacing Linux 6.1.155. The approved x86
image digest advances with the release; verification remains fail closed.
Running VMs and saved spores retain their existing kernels. Create fresh VMs
with the updated defaults to use the new kernel.

## v0.17.0

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

## v0.16.0

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
