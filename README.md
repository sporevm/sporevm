# SporeVM

SporeVM is an aarch64 virtual machine monitor for forkable Linux microVM
checkpoints. A spore is a sealed VM checkpoint: normalized machine state,
device state, verified memory chunks, optional rootfs state, and a platform
contract that fails closed when a host cannot restore it.

The 1.0 surface is aimed at warm CI and agent fan-out:

1. Start a runtime once.
2. Capture it at a useful point.
3. Fork cheap child spores.
4. Resume the children on compatible aarch64 hosts without copying all RAM for
   every child.

SporeVM targets the useful arm64 overlap:

- KVM on Linux/aarch64.
- Hypervisor.framework on Apple Silicon macOS.

Both backends expose the same small guest-visible board: fixed RAM layout,
interrupt wiring, boot contract, virtio-mmio console, blk, net, vsock, rng, and
the SporeVM generation device. Cross-backend restore is diagnostic. The product
path is same-host-class capture, fork, distribution, and resume.

## Install

Download the Linux ARM64 or macOS ARM64 archive from
[GitHub releases](https://github.com/buildkite/sporevm/releases/latest):

```bash
asset=spore_Darwin_arm64 # or spore_Linux_arm64
tar -xzf "$asset.tar.gz"
"$asset/bin/spore" version
```

Use `spore_Linux_arm64` on Linux. Add `$asset/bin` to `PATH`, or move the
extracted directory wherever you keep standalone tools.

## Build from source

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run check
mise run install
```

`mise run check` runs unit tests, the product build, and diff hygiene.
`mise run install` installs an optimized `spore` into `~/bin`.
Source builds require `cpio` in `PATH` so the minimal exec initrd can be
generated and embedded into the binary.

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
  -- /bin/true
```

Run another command from that completed base spore:

```bash
spore run --from /tmp/base.spore -- /bin/echo resumed
```

`--from` resumes the spore, attaches any verified immutable rootfs artifact and
sealed writable disk chain recorded in the manifest, sends the new argv to the
restored exec agent, streams stdout and stderr, and exits with the guest command
status.

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

Named VM lifecycle commands are available, but they are not part of the default
stable CLI surface. Opt in explicitly:

```bash
export SPOREVM_EXPERIMENTAL_MONITOR=1
export SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo

spore create bench-1 --image docker.io/library/alpine:3.20
spore exec bench-1 -- /bin/echo hi
spore ls
spore rm bench-1
```

Monitor processes run with a denied-child-exec jail on macOS and Linux. The
broader lifecycle surface remains experimental while disk-backed lifecycle
suspend/resume and jail policy mature.

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

Known limits:

- Hosts and guests are aarch64 only.
- Cross-backend restore is diagnostic, not the product path.
- General block-device state is out of scope. Rootfs-bound writable state is
  represented as sealed disk layers.
- Named lifecycle monitor commands require `SPOREVM_EXPERIMENTAL_MONITOR=1`.
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
```

Repeatable benchmark runs live in [docs/benchmarks.md](docs/benchmarks.md).
The release notes in [docs/releases/v1.0.0.md](docs/releases/v1.0.0.md) list
the A1/KVM release gate.

## Release

Releases are tag driven:

```bash
SPOREVM_RELEASE_VERSION=vX.Y.Z mise run release
```

`mise run release` runs local checks, verifies `src/root.zig` matches the target
version, and pushes the tag. The Buildkite tag build creates Linux ARM64 and
macOS ARM64 archives, writes `checksums.txt`, and publishes the GitHub release.
Use `mise run release:snapshot` to build release archives locally without
publishing.

## Security

Read [SECURITY.md](SECURITY.md) before changing virtqueue parsing, manifest or
bundle decoding, guest memory access, rootfs materialization, or monitor control
paths.

## License

[MIT](LICENSE)
