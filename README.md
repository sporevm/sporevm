# 🍄 SporeVM

SporeVM is a small aarch64 virtual machine monitor for forkable Linux microVM
checkpoints.

That sounds like another VMM, which is not really the point. The point is that
CI keeps paying to build the same warm machine over and over: boot Linux, start
services, install dependencies, load application code, migrate databases, fill
caches, run one shard, throw the machine away. SporeVM is a bet that the warm
machine should become a build artifact.

A spore is that artifact: a sealed VM checkpoint with normalized machine state,
device state, verified memory chunks, optional rootfs state, and a platform
contract that fails closed when a host cannot restore it honestly.

The useful shape is:

1. Start a runtime once.
2. Warm it up until the expensive boring work is done.
3. Capture it at a clean point.
4. Fork cheap child spores.
5. Resume the children on compatible aarch64 hosts without copying all RAM for
   every child.

The interesting bit is not "can boot Linux". Plenty of things can boot Linux.
The interesting bit is making VM state inspectable, content-addressed,
forkable, and honest enough to move around.

## What is different

- **The spore is the product.** It is not a giant opaque memory dump. It is a
  small, versioned checkpoint with a manifest, verified chunks, rootfs identity,
  and enough platform contract to say "yes, this host can restore it" or fail
  before pretending.
- **The fake computer is intentionally boring.** SporeVM targets the useful
  arm64 overlap: KVM on Linux/aarch64 and Hypervisor.framework on Apple Silicon
  macOS. Both expose the same fixed guest-visible board: RAM layout, interrupt
  wiring, boot contract, virtio-mmio console, blk, net, vsock, rng, and the
  SporeVM generation device.
- **Fork is mostly paperwork.** Children point at the same verified chunks. On
  same-host paths, trusted RAM backing can be mapped privately so reads share
  pages and writes diverge. Many children should not mean many copies of mostly
  identical RAM.
- **Forked guests are told they forked.** The generation device gives the guest
  a small hook for new identity, entropy, clock, hostname, and shard fixups.
  Without that, cloned machines become very expensive flakiness generators.
- **CI is the proving workload.** The scheduler still owns placement, secrets,
  network policy, and artifact upload. SporeVM is the machine-state primitive:
  warm once, fork many, run the shards.

SporeVM 1.0 expects spores to resume on the same backend and compatible host
class they were captured for: KVM/aarch64 to KVM/aarch64, or Apple Silicon HVF
to Apple Silicon HVF. The repo still keeps KVM/HVF restore checks because they
catch backend-specific state leaking into the spore format, but users should
not plan distribution around moving one running machine between those
hypervisors.

## Install

If you use [mise](https://mise.jdx.dev), install it globally:

```bash
mise use -g github:buildkite/sporevm@latest
spore version
```

Or download the Linux ARM64 or macOS ARM64 archive from
[GitHub releases](https://github.com/buildkite/sporevm/releases/latest):

```bash
asset=spore_Darwin_arm64 # or spore_Linux_arm64
tar -xzf "$asset.tar.gz"
"$asset/bin/spore" version
```

Use `spore_Linux_arm64` on Linux. Add `$asset/bin` to `PATH`, or move the
extracted directory wherever you keep standalone tools.

## Use as a library

`spore` is the CLI. `libspore` is the embedding surface for Zig, C, and
eventually Go callers.

Zig callers import the `libspore` module from this package. C callers should
download the matching `libspore_Linux_arm64` or `libspore_Darwin_arm64` archive
from GitHub releases and link with `pkg-config`:

```bash
asset=libspore_Darwin_arm64 # or libspore_Linux_arm64
tar -xzf "$asset.tar.gz"
export PKG_CONFIG_PATH="$PWD/$asset/lib/pkgconfig"
cc my_program.c -o my_program $(pkg-config --cflags --libs libspore)
```

See [docs/libspore.md](docs/libspore.md) for the current API.

## Build from source

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run check
mise run install
```

`mise run check` runs unit tests, the product build, and diff hygiene.
`mise run install` builds an optimized `spore` and installs it into `~/bin`,
with runtime assets under `~/share/sporevm`.
`mise run smoke` builds once, then runs product run, run-capture, and resume
smokes. `smoke:lifecycle` checks named create, repeated exec, named live fork,
list, and remove on the selected backend. `smoke:run-file-locking` checks that
the managed run kernel supports guest `flock(2)` behavior needed by Docker and
containerd volume metadata. `smoke:run-cgroup` checks that the run guest mounts
writable cgroup2 at `/sys/fs/cgroup`, which Docker needs before daemon startup.
`smoke:run-net-config` checks the experimental `spore run --net` static guest
link setup, and `smoke:run-net-dns` checks DNS
proxying through the managed gateway. `smoke:counter-fanout` and
`smoke:rootfs-fanout` are opt-in demo smokes; the rootfs fan-out smoke builds a
published Ruby OCI image and runs fresh commands in forked children in parallel.
`smoke:live-rootfs-fanout` captures an already-running Ruby rootfs workload and
checks resumed children can discover their distinct fan-out identity.
`smoke:writable-rootfs` verifies local writable rootfs disk layers across
capture, fork divergence, bundle pack/unpack, and `run --from`.

For local iteration:

```bash
mise run build
zig-out/bin/spore version
```

## Run a command

Run one command in a throwaway VM:

```bash
spore run -- /bin/writeout
```

`spore run` uses the managed SporeVM run kernel and the embedded minimal exec
initrd. On first use it downloads the managed kernel, verifies it, checks the
release kernel config for required runtime features, then caches it under the
platform cache directory.

Override boot assets when needed:

```bash
spore run --kernel Image --initrd root.cpio -- /bin/writeout
```

Use `spore --debug run ...` for verbose VMM setup and restore logs.

## Run from an OCI image

Build or reuse a cached ext4 rootfs from an OCI reference, then run an explicit
argv inside it:

```bash
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

`--image` applies OCI `Env` and `WorkingDir` when present. It does not apply
OCI `Entrypoint`, `Cmd`, or `User`; the command after `--` is always the
command SporeVM runs.

Build a reusable rootfs artifact explicitly:

```bash
spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

spore run --rootfs alpine.ext4 -- /bin/echo hi
```

Use `spore rootfs import-oci ... --ref local/name:tag` for local Docker buildx
OCI layouts that have not been pushed to a registry. Set
`SPOREVM_ROOTFS_CACHE_DIR` to override the rootfs cache.

## Networked runs

SporeVM-managed networking is explicit:

```bash
spore run --net --allow-host example.com \
  --image docker.io/library/alpine:3.20 \
  -- /bin/wget -qO- https://example.com
```

Use `--allow-host` or `--allow-cidr` to open egress beyond the built-in deny
floor. Captured network policy is replayed by `spore run --from`; omit `--net`
and allow flags on resumed runs.

## Capture and resume

Capture a run when the command exits:

```bash
spore run --image docker.io/library/alpine:3.20 \
  --capture /tmp/base.spore \
  -- /bin/sh -lc 'echo warmed > /var/tmp/example'
```

Run another command from that completed base spore:

```bash
spore run --from /tmp/base.spore -- /bin/cat /var/tmp/example
```

`--from` resumes the spore, attaches any verified immutable rootfs artifact and
sealed writable disk chain recorded in the manifest, sends the new argv to the
restored exec agent, streams stdout and stderr, and exits with the guest command
status.

For image captures, filesystem writes under the rootfs are portable through the
sealed disk chain. General attached block devices are not part of the product
contract.

Capture a running workload on a host signal:

```bash
spore run \
  --capture /tmp/live.spore \
  --capture-on USR1 \
  -- /bin/sleeper &
run_pid=$!

kill -USR1 "$run_pid"
wait "$run_pid"
spore resume /tmp/live.spore
```

With plain `--capture DIR`, SporeVM captures after guest command exit. With
`--capture-on SIGNAL`, the first matching host signal writes the spore and
exits zero. Add `--continue-after-capture` to keep the original run alive after
a signal-triggered capture.

## Fork and fan out

Fork an existing spore:

```bash
spore fork /tmp/base.spore --count 100 --out /tmp/forks
```

Children are named `000000`, `000001`, and so on. They share the parent chunk
store and get distinct generation metadata.

Resume forked children locally with prefixed output:

```bash
spore fanout /tmp/forks --parallel --for 20s
```

See [docs/fanout.md](docs/fanout.md) for the child identity contract.

## Pack and distribute

Pack a spore, optionally with forked children:

```bash
spore pack /tmp/base.spore --children /tmp/forks --out /tmp/base.bundle
```

Unpack or pull one selected child before resume:

```bash
spore unpack /tmp/base.bundle --child 000042 --out /tmp/child.spore
spore resume /tmp/child.spore
```

Remote pulls are digest-pinned:

```bash
spore pull s3://bucket/path/base.bundle@sha256:<bundle-digest> \
  --child 000042 \
  --out /tmp/child.spore
```

`spore pack`, `spore unpack`, `spore push`, and `spore pull` carry memory
chunks, immutable rootfs artifacts, chunked rootfs storage, and sealed writable
disk layers. Bytes from local caches, bundles, S3, and HTTP(S) peers are
verified before use.

## Named lifecycle

Named VM lifecycle is stable on supported HVF/KVM backends:

```bash
export SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo

spore create bench-1 --image docker.io/library/alpine:3.20
spore exec bench-1 -- /bin/echo hi
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
spore ls
spore rm bench-2
```

Machine callers can use `spore --json create`, `spore --json suspend`,
`spore --json resume`, `spore --json fork`, `spore --json ls`, and
`spore --json rm` for structured lifecycle state. `spore exec` forwards guest
stdout and stderr as workload streams.

Fork a running diskless named VM into named children while keeping the source
running:

```bash
export SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo

spore create golden
spore exec golden -- /bin/true
spore fork --vm golden --count 2 --name worker-%d
spore exec worker-0 -- /bin/writeout
spore exec golden -- /bin/true
spore rm worker-0
spore rm worker-1
spore rm golden
```

Hidden fork batches are retained until children no longer reference them. Use
`spore system prune --older-than 1d` to dry-run cleanup of old unreferenced
batches, then add `--force` to delete them.

Monitor processes run with a denied-child-exec jail on macOS and Linux. Named
checkpoint lifecycle supports diskless VMs, image-created writable rootfs state,
and explicit `--rootfs` path checkpoints backed by exact immutable rootfs
artifacts. Named live fork is currently diskless-only.

## What 1.0 supports

- One-shot `spore run`, signal capture, `spore resume`, `spore run --from`,
  `spore fork`, and local `spore fanout`.
- Rootfs-backed runs from OCI images or explicit ext4 files.
- Manifest-attached immutable rootfs identity, chunked rootfs storage, and
  sealed writable rootfs disk layers for `spore run --image ... --capture`.
- Local bundle pack/unpack and digest-pinned S3 or HTTP(S) pull/push paths for
  selected children.
- Managed kernel download and verification for the default run path.
- Spore-managed guest networking for DNS, HTTP/HTTPS, persisted egress policy,
  and hard-floor egress denial.
- Named lifecycle `create`, `exec`, `suspend`, `resume`, `fork --vm`, `ls`, and
  `rm` on supported HVF/KVM backends.

Known limits:

- Hosts and guests are aarch64 only.
- Resume is for compatible host classes: KVM/aarch64 spores resume on
  KVM/aarch64, and Apple Silicon HVF spores resume on Apple Silicon HVF. KVM
  to HVF restore checks exist to catch bad state serialization, not as a 1.0
  user contract.
- General block-device state is out of scope. Rootfs-bound writable state is
  represented as sealed disk layers.
- Explicit `spore create --rootfs PATH` lifecycle checkpoints use exact rootfs
  artifacts, not chunked rootfs storage; use `--image` for the chunked CAS fast
  path.
- Named live fork is diskless-only until disk-backed and networked fork support
  are added.
- SporeVM is a VMM isolation boundary, but it does not claim hardened
  public-cloud multi-tenant isolation.

## Validation

Most local changes should start here:

```bash
mise run check
mise run smoke
```

Useful focused checks:

```bash
mise run smoke:run
mise run smoke:run-capture
mise run smoke:rootfs-fanout
mise run smoke:writable-rootfs
mise run smoke:run-net-dns
mise run smoke:monitor-jail
mise run smoke:monitor-failure-modes
```

Repeatable benchmark runs live in [docs/benchmarks.md](docs/benchmarks.md).
The release notes in [docs/releases/v1.2.0.md](docs/releases/v1.2.0.md) list
the A1/KVM release gate.

## Release

Releases are tag driven:

```bash
SPOREVM_RELEASE_VERSION=vX.Y.Z mise run release
```

`mise run release` runs local checks, verifies `src/root.zig` matches the target
version, and pushes the tag. The Buildkite tag build creates Linux ARM64 and
macOS ARM64 CLI archives plus matching `libspore` archives, writes
`checksums.txt`, and publishes the GitHub release. Use
`mise run release:snapshot` to build release archives locally without publishing.

## Security

Read [SECURITY.md](SECURITY.md) before changing virtqueue parsing, manifest or
bundle decoding, guest memory access, rootfs materialization, or monitor control
paths.

## License

[MIT](LICENSE)
