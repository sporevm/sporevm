# Release Notes

## Unreleased

## v0.18.5

- `checkpoint pull --local-ram-backing` builds a verified sparse RAM backing
  once on the receiving host, allowing restores and offline forks to share
  clean pages through the existing private-mapping path. The default pull is
  unchanged. This costs one extra local copy of nonzero logical RAM on disk;
  portable checkpoint identity and chunk authority remain unchanged.

## v0.18.4

- TCP relays send short writes without waiting for Nagle and delayed ACKs,
  on both the guest-facing stack and outbound host sockets.
- TCP transmit windows grow from 16 to 64 KiB, and the VMM receive queue
  accepts a complete 64-frame helper output batch instead of dropping frames
  after the first 16. The bounded TCP pool grows from about 13 to 25 MiB.
- Managed kernels move to
  [v0.7.4](https://github.com/sporevm/kernels/releases/tag/v0.7.4), enabling
  ARM64 high-resolution timers. Requested 1-ms sleeps take about 1.06 ms
  instead of 4 ms in the measured KVM guest; the x86_64 kernel is unchanged.
  Start fresh VMs to use the new kernel; existing VMs and checkpoints keep
  their booted kernel. ARM64 build steps cached with the old kernel rerun once.

## v0.18.3

### Highlights

This patch release fixes a guest kernel crash that SporeVM v0.17.1 through
v0.18.2 could hit under memory pressure, and replaces the guest kernel's slow
memory allocator. A Buildkite cold CI setup in an ARM64 VM ran into both on
v0.18.2 and timed out after an hour. ([#705](https://github.com/sporevm/sporevm/pull/705))

- **The guest kernel no longer oopses after ext4's allocator cache is
  evicted.** Linux 6.1.191, the managed kernel since v0.17.1, backported an
  ext4 change that dereferences NULL when memory pressure has evicted the
  block allocator's cache. The next file write, `mkdir` or delete in the
  affected block group oopsed, and the guest's filesystem often hung. Root
  filesystems in every format were affected. The managed kernels move to
  [kernels v0.7.3](https://github.com/sporevm/kernels/releases/tag/v0.7.3),
  which carries the upstream 6.1.y fix.
- **Managed kernels use SLUB instead of SLOB.** SLOB's free-list scan took
  most of the guest's CPU time in metadata-heavy work. In a 4 vCPU / 8 GiB
  ARM64 KVM guest, creating 6,400 empty files went from 110 ms to 35 ms, and
  building the Buildkite agent from 190 s to 70 s. These are workload-specific
  measurements.
- **x86_64 gets the same kernel fixes.** The approved x86_64 bzImage is
  rebuilt with SLUB, the NULL-pointer fix, and the ext4 inode-reuse patch that
  ARM64 received in v0.18.1.

### Upgrading from v0.18.2

- Image, chunk, checkpoint and wire formats remain compatible, and the
  conversion builder is unchanged. Existing images and checkpoints remain
  readable and are not rewritten.
- **Start fresh VMs to get the fix.** Running VMs and saved checkpoints keep
  the kernel they booted with, so checkpoints saved on v0.17.1 through v0.18.2
  still run the affected kernel. Recreate them from a fresh boot.
- **Build steps cached with the previous managed kernel rerun once** on both
  architectures, because both kernel SHAs changed.
- Upgrading from v0.18.1 or earlier still requires the applicable upgrade
  notes below.

## v0.18.2

### Highlights

This patch release fixes the guest-loopback limitation documented in v0.18.1.
Guest-local services can communicate through `127.0.0.1` or `localhost`
without enabling outbound networking. ([#703](https://github.com/sporevm/sporevm/pull/703))

- **Loopback works independently of egress.** Guest init brings up `lo` as
  `127.0.0.1/8`, even without `--net` and in builds with `--network none`.
  Kernels with IPv6 enabled also bring up `::1`. This does not enable egress
  or access to host-local services.
- **Missing localhost hosts entries get defaults.** The initrd includes
  localhost entries in `/etc/hosts`. OCI/tar conversion supplies them when
  `/etc/hosts` is absent, preserving image-provided files and symlinks.

### Upgrading from v0.18.1

- Image, chunk, checkpoint and wire formats remain compatible. Existing
  immutable images and checkpoints remain readable and are not rewritten.
- **Recreate old checkpoints to get initialized loopback**, or configure it
  inside the guest. Restoring a checkpoint does not rerun guest init. New
  checkpoints and forks retain the initialized loopback configuration.
- Conversion builder `sporevm-rootfs-v8` invalidates previous conversion-cache
  keys. Reconverted OCI/tar inputs produce new filesystem bytes and content
  digests. Reconvert images missing `/etc/hosts` to get the localhost defaults;
  existing native images and caller-supplied raw rootfs disks keep their own
  hosts configuration.
- The managed kernel remains [kernels v0.7.2](https://github.com/sporevm/kernels/releases/tag/v0.7.2)
  (Linux 6.1.191); this release does not change kernel bytes.
- Upgrading from v0.18.0 or earlier still requires the applicable upgrade
  notes below.

## v0.18.1

### Highlights

This patch release fixes networking and filesystem bottlenecks in native
builds. With these fixes, Buildkite's unchanged native setup went from failing
inside a VM to completing in 570 seconds on ARM64 KVM. In a repeated
small-file probe, a batch of 2,500 files went from about 390 ms to
about 14 ms with the new kernel. These are workload-specific measurements,
not a promise of the same speedup on every host.

- **Parallel downloads no longer hit an eight-connection ceiling.** Managed
  guest networking allows 256 concurrent outbound TCP flows. Once the pool
  is full, new connections are refused promptly rather than left waiting for
  retries. DNS saturation returns SERVFAIL, and dispatch bursts stay within
  the helper's bounded frame queues. ([#699](https://github.com/sporevm/sporevm/pull/699))
- **Large rootfs directories get native ext4 indexes.** The rootfs writer now
  emits htrees for populated multi-block directories and extent trees for
  files, directories and long symlinks. Enabling `dir_index` also lets Linux
  index new directories as they grow, avoiding linear directory lookups.
  The deterministic, journal-less profile, content deduplication and lazy
  rootfs reads are retained. ([#700](https://github.com/sporevm/sporevm/pull/700))
- **Repeated file creation stays fast on ARM64.** The managed kernel moves to
  [kernels v0.7.2](https://github.com/sporevm/kernels/releases/tag/v0.7.2),
  patching Linux 6.1.191's quadratic journal-less ext4 inode allocation.
  Freed inodes can be reused immediately rather than repeatedly scanned for
  minutes after deletion. x86_64 keeps the same approved, unpatched bzImage.
  ([#701](https://github.com/sporevm/sporevm/pull/701))

### Upgrading from v0.18.0

- Image, chunk, checkpoint and wire formats remain compatible. Existing
  immutable images and checkpoints remain readable with their exact identities;
  upgrading does not rewrite them or require recreating checkpoints.
- Conversion builder `sporevm-rootfs-v7` invalidates old conversion-cache keys.
  Reconverted OCI/tar inputs produce new filesystem bytes and content digests.
  Reconvert those inputs to get indexed directories and extent trees; existing
  native images do not acquire the new profile automatically.
- **ARM64 build steps cached with the previous managed kernel rerun once**
  because the kernel SHA changed. x86_64 kernel bytes and its kernel-based cache
  identity are unchanged. Running VMs and saved checkpoints retain their old
  kernels; start a fresh VM with the new managed kernel to get the inode fix.
- Upgrading from v0.17.1 or earlier still requires the migrations documented
  under v0.18.0 below.

### Known issue

Guest loopback is still not brought up by default. Workloads that depend on
guest-local services through `127.0.0.1` or `localhost` must bring up `lo`
inside the guest (for example, `ip link set lo up`, where available).
This release does not fix that limitation.

## v0.18.0

### Upgrading

v0.18.0 gives each command one spelling and resets SporeVM's local formats;
it reads nothing earlier versions saved.

#### Scripts already tracking unreleased main

The unreleased-main spellings below are replaced before 0.18.0. They are not
executable aliases: obsolete flags/commands fail with a correction. This adds
a migration for scripts already tracking main as well as the 0.17.1 upgrade.

| Previous main | Canonical spelling |
| --- | --- |
| `attach DIR` | `checkpoint resume DIR` |
| `fanout BATCH` | `checkpoint fanout BATCH` |
| `image export REF` | `image export-rootfs REF` (registry, local or native-store images) |
| `build -t REF CONTEXT` | `build CONTEXT --tag REF` |
| Import/unpack `--ref REF` | `--tag REF` |
| Artifact `--out PATH` | `--output PATH` |
| `image push REF STORE/TAG` | `image push REF --to STORE/TAG` |
| `checkpoint push DIR STORE/TAG` | `checkpoint push DIR --to STORE/TAG` |
| `run --from DIR` | `run --checkpoint DIR` |
| `run --save DIR`, `--commit REF` | `--save-checkpoint DIR`, `--commit-image REF` |
| `vm restore DIR --name NAME` | `vm restore NAME --checkpoint DIR` |
| `vm fork NAME --name PATTERN` | `vm fork NAME --name-prefix PREFIX` → `PREFIX-0…PREFIX-(N-1)` |
| `vm logs NAME` | `vm logs NAME --initial` (bounded initial output, not exec history) |
| Unpack `--archive-digest DIGEST` | `--expected-archive-digest DIGEST` |
| Bare guest command/string | `-- ARGV…` or `--shell STRING` |
| `run` / `vm create --timeout DURATION` | `--startup-timeout DURATION` for readiness, `--exec-timeout DURATION` for commands |
| Build `--timeout DURATION` | `--step-timeout DURATION` (legacy alias accepted) |

Command options work before or after resource operands until `--`; global
`--json`/`--debug` must precede the command. Duplicate scalar flags fail,
while collection flags retain repetition. Options-file JSON keys, result
schemas, and event identifiers (`attach`, `fanout`, `exec`) are unchanged.
Both output modes now use classified failure statuses, including named exec
readiness failures (22, not human-only 2). Push results add immutable
`digest_ref` and nullable mutable `tag_ref`, preserving legacy `ref` meanings.

Registry/layout/tar selection defaults to host-native Linux. Pack, push and
unpack infer a single recorded platform; explicit selection never substitutes
another platform. Disk-backed checkpoint summaries identify cache-pinned
storage rather than implying a standalone portable `.spore` artifact.

`image pull SOURCE [--tag local/NAME:TAG]` now acquires a complete verified image
without booting and returns a native local digest reference for offline use.
Registry tags refresh; native inputs preserve their recorded platform. Local
and native-store images can also be exported as independent writable ext4 files
with native-identity metadata, without fabricated OCI provenance.

S3 reads now use AWS CLI v2's profile/provider chain when explicit environment
credentials are absent, and refresh expiring provider credentials before use.
Startup readiness uses `--startup-timeout`, commands use `--exec-timeout`
(including per-exec overrides), builds use `--step-timeout`, and resumed saved
sessions use `--for`. Execution alone accepts `none`; resumed sessions no
longer inherit a hidden 30s limit. These do not bound artifact acquisition or
the whole operation. Named exec timeouts cancel descendants while preserving
the VM and its initial command. Named exec process trees now belong to the
invocation, including normal completion; start long-lived background services
as the detached `vm create` initial command instead of `vm exec ... &`.
Legacy timeout spellings remain accepted.

Checkpoint format is now v8 because saved RAM includes the guest agent that
implements client-owned command cancellation. Re-create checkpoints from
formats 0–7; rewriting their version cannot upgrade the saved agent. Native
image layout is unchanged. `--save-on INT` makes Ctrl-C save successfully,
not cancel; human mode prints a notice.
Pinned Kubernetes deployments must stay on their current CLI until the removed
bundle workflow is migrated and tested; this is not a coordinated k8s upgrade.

#### Upgrading from v0.17.1

Commands on named VMs live under `spore vm`, saved state under
`spore checkpoint`, host and cache maintenance under `spore system`, and image
commands under `spore image`. The old executable spellings are gone; use these
canonical forms:

| Old | New |
| --- | --- |
| `spore create`, `exec`, `copy-in`, `copy-out`, `save` | `spore vm create`, `vm exec`, `vm copy-in`, `vm copy-out`, `vm save` |
| `spore logs NAME` | `spore vm logs NAME --initial` |
| `spore restore DIR --name NAME` | `spore vm restore NAME --checkpoint DIR` |
| `spore rm NAME`, `ls`, `ps` | `spore vm rm NAME`, `vm ls` |
| `spore fork --vm NAME` | `spore vm fork NAME` |
| `spore fork DIR`, `inspect DIR`, `rm --spore DIR` | `spore checkpoint fork DIR`, `checkpoint inspect DIR`, `checkpoint rm DIR` |
| `spore host-info` | `spore system info` |
| `spore cache gc`, `cache pins`, `cache unpin` | `spore system gc`, `system pins`, `system unpin` |
| `spore rootfs import-oci`, `rootfs import-tar`, `rootfs resolve` | `spore image import-oci`, `image import-tar`, `image resolve` |
| `spore rootfs build` | `spore image export-rootfs` (registry, local or native-store images) |

`checkpoint resume` continues a checkpoint's saved process in a throwaway VM;
it does not connect to a named VM. `vm restore NAME --checkpoint DIR` creates
a named live VM, while `run --checkpoint DIR -- COMMAND` starts a new command
in restored state.

- Global `spore --json` with `run`, `checkpoint resume`, `checkpoint fanout`
  or `vm exec` prints the
  `spore.automation.event.v1` stream that `--events=jsonl` printed, and
  `--events=jsonl` is gone from every command. Argument errors in those
  commands end the stream with a failed `completion` instead of a message on
  stderr. `spore vm restore` no longer streams events. Other JSON results keep
  their schemas.
- Removed commands: bundles (`spore pack`, `unpack`, `inspect-bundle`, and
  `spore push` and `pull` of bundles) and `spore clone`, replaced by
  `spore checkpoint push` and `pull`; `spore help` (use `spore --help`),
  `spore rootfs cas-preload`, `spore exec --timing-json`
  and `spore image export-fixture`. The old experimental image-pull protocol
  is not restored: `spore image pull` now acquires verified native content
  for offline use without booting. Only `-h` and `--help` ask for help, so
  `spore checkpoint rm help` removes `./help`.
- `spore checkpoint resume` without `--json`, and so `spore checkpoint fanout`, prints the
  session's stdout and stderr instead of the guest console.
- The guest copies command output to the console, and so to a console log,
  only in VMs started with `--console-log`. A spore saved from a VM started
  without it does not gain it when restored with `--console-log`.
- `spore build` refuses a runtime directory that isn't private to the
  current user (mode 0700), such as a shared `SPOREVM_RUNTIME_DIR`.
- The C ABI (`spore.h` and the `libspore` archives), the Go binding and the
  Zig `libspore` module are gone. The CLI's `--json` output is the only
  interface.
- The e2fsprogs ext4 writer is gone, with `SPOREVM_EXT4_WRITER=external` and
  the `--mkfs` and `--debugfs` options of `spore build` and `spore rootfs`.
- Re-create saved spores and checkpoints from earlier versions; they fail
  with `FormatTooOld`. Spore manifests are version 8, one shape for any vCPU
  count, and disk and memory indexes are only `spore-disk-index-v2`.
- Saved RAM carries the guest agent, which now speaks only the SPIO exec
  protocol and parses every request strictly. The text protocol and its
  `start`, `attach` and `generation` requests are gone.
- Saved-spore pins are `spore.saved-disk-pin.v3`. Older pins root nothing;
  `spore system pins` lists them as `stale` and `spore system gc` deletes them.
- Local RAM backing proofs are v3, without fs-verity. Spores with an older
  proof restore from their verified chunks instead.
- On macOS the GICv3 redistributors moved to `0x08020000`, where KVM has them.
  HVF spores from earlier builds fail with `PlatformMismatch`.
- Stop named VMs before upgrading. A VM is live only while its monitor holds
  `vms/<name>/lock`, which older monitors don't take, so their VMs show as
  stale. `spore vm rm NAME` removes them, and any VM whose spec has removed
  fields. `spore vm ls` shows `starting` where `spore ls` showed `incomplete`.
- Local images from earlier versions (built, committed, imported or unpacked)
  are no longer listed; build or import them again. Registry images are
  pulled again on first use.
- To reclaim space, delete the `rootfs` and `bundles` directories under the
  SporeVM cache (`~/.cache/sporevm` on Linux, `~/Library/Caches/sporevm` on
  macOS, or `SPOREVM_ROOTFS_CACHE_DIR`). `SPOREVM_BUNDLE_CACHE_DIR` is no
  longer read. Otherwise the first `spore system gc` deletes step records from
  older builders and the objects only they and old indexes kept.
- The first `spore build` after upgrading misses its cache once, because the
  guest initrd changed.
- JSON: `spore system info` reports only `spore.host-info.v3`, without
  `cache_roots.bundles`. `spore.cache.gc.result.v2` drops
  `legacy_step_record_count` and `unparseable_ref_count`.
  `spore.rootfs.import.result.v2` drops `rootfs_path` and reports the image
  identity as `image_manifest_digest`. `spore.saved.remove.result.v2` drops
  `ownership`, `pin_id` and `pin_removed`. The removed commands' results, the
  `bundle` resource type and `spore.named-exec-timing.v1` are gone.

### Security

- A `spore build` RUN step could leave its root through a nested chroot
  (BuildKit also grants `CAP_SYS_CHROOT`) and reach the build VM's
  initramfs, with its guest-wide `/proc`, cgroup tree and build disks.
  v0.17.1 is affected. The RUN root is now moved over `/` before the chroot,
  as switch_root does. RUN still can't create user namespaces, now
  enforced by seccomp, and `clone3` reports `ENOSYS`, as under BuildKit's
  default profile.
- x32 syscalls are killed in the monitor jail and in build RUN steps.
- `spore vm copy-out` stops at 4 GiB of guest archive, applies the host umask,
  and can't be redirected by symlinks the guest swaps in. Guest output during
  a copy no longer reaches stdout, and stderr has control bytes escaped.
- The guest agent reads generation params (from `--generation` files, forks
  and restores) in one pass over the JSON object, so a nested object or a
  look-alike key can't supply a member's value. Params that aren't valid JSON,
  repeat a member the agent reads, give it the wrong type, or set a VM id,
  fork batch id, hostname or entropy seed over 127 bytes or containing NUL now
  fail instead of being partly applied. `spore run --checkpoint`, `spore checkpoint resume` and
  `spore vm restore` check a `--generation` file the same way before the VM
  starts.
- Virtqueue rings are checked against guest RAM when a queue becomes ready and
  on restore, and ring accesses are ordered on multi-vCPU arm64.
- Manifests listing more than eight GIC redistributors are rejected instead of
  hanging validation.
- Image layers and image archives are read through one fuzzed tar parser.

### Image stores

- `spore image push local/app:1 --to DEST` writes a static image store to a
  directory, or to `s3://bucket/prefix` with the aws CLI.
- `spore image pull SOURCE` acquires all verified objects into rooted local
  storage without booting. Its immutable native digest works offline until
  explicit image pruning. `image resolve` remains identity-only and
  `run --image` remains lazy. `image export-rootfs` also accepts native local
  and store inputs and writes an independent writable ext4 copy.
- `spore run --image` and `spore vm create --image` boot a store ref
  (`file://`, `https://` or `s3://`, by tag or `blake3:<hex>`) with only the
  image's manifest, config and index local. Each rootfs object the guest reads
  is fetched on first use, with the objects of the next 7 chunks.
- `--save-checkpoint`, `--save-on`, `--commit-image` and `spore vm save` first fetch the rest
  of the image, so the result needs nothing from the store.
- `spore checkpoint push SPORE --to STORE/TAG` writes a saved spore to a directory
  or S3 store. Its RAM chunks and disk objects share the store's `objects/`, so
  pushing to the store that holds its image uploads only the RAM, the changed
  disk chunks, the disk index and the manifest. `spore checkpoint pull
  STORE/TAG --output DIR` fetches it from a directory, HTTP(S) or S3 store,
  verifies every object and writes a save pinned in the rootfs cache. To run
  one child of a fork batch elsewhere, push the parent, pull it there and pass
  the child's identity to `spore run --checkpoint DIR --generation FILE`.
- S3 reads use explicit environment credentials or AWS CLI v2's credential
  chain, including `AWS_PROFILE` and renewable role credentials. Provider
  credentials refresh before expiry; explicit environment credentials remain
  fixed. Region comes from `AWS_REGION`, `AWS_DEFAULT_REGION`, or the selected
  profile. `AWS_ENDPOINT_URL` and `AWS_ENDPOINT_URL_S3` still fail closed.
  Readers need `s3:GetObject`. See `docs/image-format.md`.

### Performance

- Guest command output reaches `spore run` and `spore vm exec` at 350 to 700
  MiB/s, up from 14 MiB/s on KVM and 30 MiB/s on Hypervisor.framework.
- Restores from memory chunks skip zero chunks and read the rest straight into
  guest RAM. In a 512 MiB VM with 32 MiB in use, skipping zero chunks cut
  loading from 324 ms to 55 ms and resident memory from 512 MiB to 32 MiB; the
  direct read takes another 28 to 43 percent off warm loads.
- On aarch64 each virtio-blk disk serves requests on its own thread, so a slow
  read, such as an object fetched from an image store, stalls only that disk:
  the vCPUs, console, network, other disks and `spore vm exec` keep working.
- A dense 32 GiB disk index decodes into 21 MB of heap instead of 226 MB, and
  once per open: such a local image opens lazily in about 0.5 s instead of
  1.4 s.
- Fresh x86 VMs no longer make all guest RAM resident at boot: a 512 MiB VM's
  monitor uses 46 MiB instead of 521 MiB.
- Idle multi-vCPU VMs no longer poll every millisecond on the host.

### Fixes

- Saves survive a crash: full-scan RAM saves fsync each chunk, every
  `manifest.json` write is atomic, and the local RAM backing is fsynced before
  its proof. On a Linux test host a full-scan save took 50 ms longer with
  32 MiB of RAM in use and 350 ms longer with 512 MiB.
- Saves wait until no vCPU is in an interrupt handler, or fail with
  `InterruptStillActive`, so restoring a multi-vCPU save on macOS no longer
  aborts.
- macOS release builds restore guest SIMD registers correctly, so commands
  started in a restored spore no longer fail with `exec setup failed`.
- `spore run --save-checkpoint` and `spore checkpoint fork --output` accept relative paths,
  and saves into a directory under a symlink, such as `/tmp` on macOS, work;
  both failed with `BadManifest`.
- `spore checkpoint resume` and `spore checkpoint fanout` resume a saved session's output where the
  `spore run` that saved it left off, and no longer fail once the session has
  written more than 64 KiB.
- `spore checkpoint resume` fails instead of exiting 0 when the guest powers off before
  reporting its exit status, or with `NetworkGatewayFailed` when the network
  gateway died.
- `spore vm rm` stops a VM within about a second while an exec runs; the exec
  fails with `named VM is being removed`.
- `vm create`, `vm restore` and `vm fork` claim names atomically, and
  `vm fork` no longer undoes a `spore vm save` that finished while it started.
- `spore system gc` collects unreferenced storage on hosts with local images,
  works after a destructive prune while disk-forked VMs run, and reads VM
  specs over 64 KiB.
- Networking: a slow DNS resolver no longer stalls other traffic, connects to
  denied addresses are refused at once, bytes sent after the host half-closes
  are delivered, and `spore run --bind-service ... --save-checkpoint` works.
- A terminal resize with a full vsock ring no longer stalls `run -t` or
  `checkpoint resume`, and single-vCPU macOS snapshots no longer drop queued vsock
  packets.

### Other changes

- `spore --help` lists every command, and a bare group such as `spore vm`
  lists its verbs.
- `SPOREVM_DOCKER_HUB_MIRROR=mirror.gcr.io` pulls `docker.io` images through
  a mirror; refs, cache keys and digests still name `docker.io`. Registry 404
  and 429 responses fail as `RegistryNotFound` and `RegistryRateLimited`.
- Cold image pulls (`run --image`, `image import-oci` and `import-tar`)
  download and merge layers without the rootfs cache lock, so other VM starts
  no longer wait for them.
- `spore build` holds the rootfs cache lock only to look up, seal and publish
  steps, so runs, saves and `system gc` no longer wait for a long build.
- `spore build` rejects an invalid later stage before any stage runs, and
  pulls `COPY --from` images only after the whole Dockerfile is planned.
- Image rootfs builds handle files larger than 4 GiB.
- `spore image pack` accepts tags from `image import-oci` and `import-tar`,
  and `spore --json image pack` and `image unpack` print result documents.
- `spore checkpoint rm DIR` deletes any checkpoint whose manifest parses, even
  with corrupt storage, and no longer refuses with `SavedSporeInUse` while a
  VM restored from it runs; that VM's runtime lease keeps its storage.
  `spore system gc --force` releases a removed checkpoint's pin.
- Saved network spores record `default_action: "deny"` for every restricted
  egress policy, including `--allow-cidr` and `--allow-host` alone; a policy
  with allow entries but no `default_action` still restores as restricted.
- `spore run`, `vm create` and `build` check the hypervisor before any
  download. Linux arm64 hosts without a usable `/dev/kvm` fail with
  `MissingKvmDevice` or `KvmOpenFailed`, and incompatible x86 hosts fail with
  `IncompatibleCpuProfile` and log which CPU fact differs. `spore system info`
  reports a `/dev/kvm` that exists but can't be opened as `kvm_open_failed`.
- Remote `ADD` and registry fetches try the host's other addresses when one
  fails to connect or closes before answering.
- The shipped guest initrd is about 45% smaller; smoke-test helpers are only
  in `-Dsmoke-helpers` builds.
- `spore image export-rootfs` keeps its temporary files in the rootfs cache instead
  of `.zig-cache/` in the current directory.

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
