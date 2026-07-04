<p align="left">
  <img src="assets/sporevm-mark-bounded.png" alt="SporeVM" width="160">
</p>

# SporeVM

[![Buildkite](https://badge.buildkite.com/43af213c90bb781b385d58fc664e5ee8f1b99502f66102e53a.svg?branch=main)](https://buildkite.com/buildkite/sporevm)
[![Release](https://img.shields.io/github/v/release/sporevm/sporevm?sort=semver)](https://github.com/sporevm/sporevm/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](mise.toml)

SporeVM is a small aarch64 virtual machine monitor for forkable Linux microVM
checkpoints.

A spore is a sealed VM checkpoint with normalized machine state, device state,
verified memory chunks, optional rootfs state, and a platform contract that
fails closed when a host cannot restore it honestly.

The useful shape is:

1. Start a runtime once.
2. Warm it up until the expensive boring work is done.
3. Capture it at a clean point.
4. Fork cheap child spores.
5. Resume the children on compatible aarch64 hosts without copying all RAM for
   every child.

SporeVM 1.0 expects spores to resume on the same backend and compatible host
class they were captured for: KVM/aarch64 to KVM/aarch64, or Apple Silicon HVF
to Apple Silicon HVF. The repo still keeps KVM/HVF restore checks because they
catch backend-specific state leaking into the spore format, but users should
not plan distribution around moving one running machine between those
hypervisors.

## Design details

- [docs/spore-format.md](docs/spore-format.md): manifest, bundle, and invariant
  contract.
- [docs/state-portability.md](docs/state-portability.md): KVM/HVF state mapping
  and fail-closed restore matrix.
- [docs/memory.md](docs/memory.md): memory chunks, local backing, and dirty
  tracking.
- [docs/filesystem.md](docs/filesystem.md): rootfs CAS and writable root disk
  layers.
- [docs/rootfs.md](docs/rootfs.md): OCI image and rootfs CLI workflows.
- [docs/fanout.md](docs/fanout.md): fork identity and fan-out behavior.
- [docs/networking.md](docs/networking.md): SporeVM-managed networking.
- [docs/lifecycle.md](docs/lifecycle.md): named VM lifecycle.
- [docs/libspore.md](docs/libspore.md): Zig, C, and Go embedding surface.

## Install

If you use [mise](https://mise.jdx.dev), install it globally:

```bash
mise use -g github:sporevm/sporevm@latest
spore version
```

Or download the Linux ARM64 or macOS ARM64 archive from
[GitHub releases](https://github.com/sporevm/sporevm/releases/latest):

```bash
asset=spore_Darwin_arm64 # or spore_Linux_arm64
tar -xzf "$asset.tar.gz"
"$asset/bin/spore" version
```

Use `spore_Linux_arm64` on Linux. Add `$asset/bin` to `PATH`, or move the
extracted directory wherever you keep standalone tools.

## Use as a library

`spore` is the CLI. `libspore` is the embedding surface for Zig, C, and Go
callers. See [docs/libspore.md](docs/libspore.md) for import, ownership, C ABI,
and Go binding details.

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
`mise run smoke` builds once, then runs the default product run, run-capture,
and resume smokes. Focused smoke commands are listed under
[Validation](#validation).

For local iteration:

```bash
mise run build
zig-out/bin/spore version
```

## Run a command

Run one command in a throwaway VM:

```bash
spore run 'echo hi'
```

`spore run` uses the managed SporeVM run kernel and the embedded minimal exec
initrd. The embedded initrd contains SporeVM helper binaries plus a small
Toybox shell environment for basic commands such as `echo`, `cat`, `printf`,
`pwd`, and `uname`. Use `--image` or `--rootfs` for distro behavior, package
managers, or commands outside that bounded set.

Exact argv after `--` still uses the path you provide without guest PATH
lookup:

```bash
spore run -- /bin/echo hi
```

Forward host stdin explicitly with `-i` when the guest process should read
input. Without `-i`, runs keep the script-friendly default and do not attach
host stdin:

```bash
printf 'hello\n' | spore run -i -- /bin/cat
```

Inject a caller-provided file into the run with `--inject ID=PATH`. The guest
sees it at `/run/sporevm/injected/ID`; the file is carried by the run
initrd and copied into rootfs `/run` tmpfs, so it is not added to the image
rootfs cache. `--inject` is rejected with `--capture` and `--from` because file
persistence would otherwise be ambiguous:

```bash
spore run --inject config=./config.json \
  --image docker.io/library/alpine:3.20 \
  -- /bin/cat /run/sporevm/injected/config
```

Allocate a guest terminal explicitly with `-t`. Use `-it` for an interactive
shell; TTY output is a single terminal byte stream, so stdout and stderr are not
separated in this mode:

```bash
spore run -it --image docker.io/library/alpine:3.20 -- /bin/sh
```

Override boot assets when needed:

```bash
spore run --kernel Image --initrd root.cpio -- /bin/writeout
```

Use `spore --debug run ...` for verbose VMM setup and restore logs.

## Run from an OCI image

Build or reuse a cached ext4 rootfs from an OCI reference, then run a shell
command inside it:

```bash
spore run --image docker.io/library/alpine:3.20 'echo hi'
```

`--image` applies OCI `Env` and `WorkingDir` when present. It does not apply
OCI `Entrypoint`, `Cmd`, or `User`. Shell commands run as `/bin/sh -lc` in the
guest. Use `-- <argv...>` when you need exact argv.

Build a reusable rootfs artifact explicitly:

```bash
spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

spore run --rootfs alpine.ext4 'echo hi'
```

See [docs/rootfs.md](docs/rootfs.md) for cache behavior, local OCI layout
imports, and rootfs pruning.

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

Use `--forward 127.0.0.1:HOST_PORT:GUEST_PORT` to expose one live guest TCP
port on host loopback while the run or named VM monitor is alive.

See [docs/networking.md](docs/networking.md) for policy, bound-service,
port-forward, and resume limits.

## Fork a live VM

Start a named VM with a running process:

```bash
spore create counter --image docker.io/library/alpine:3.20 \
  'i=0; while true; do echo "$i" > /tick; i=$((i + 1)); sleep 1; done'
```

Fork it while that process is still running:

```bash
spore fork --vm counter --count 2 --name child-%d
```

Both children keep running from the fork point:

```bash
spore exec child-0 'cat /tick; sleep 1; cat /tick'
spore exec child-1 'cat /tick; sleep 1; cat /tick'
```

Named exec can also be interactive when you opt in to input or a terminal:

```bash
printf 'hello\n' | spore exec -i child-0 -- /bin/cat
spore exec -it child-0 -- /bin/sh
```

Copy explicit files or directories into or out of a named VM:

```bash
spore copy-in child-0 ./local.txt /tmp/local.txt
spore copy-out child-0 /tmp/local.txt ./roundtrip.txt
spore copy-in child-0 ./src /tmp/src
spore copy-out child-0 /tmp/src ./src-roundtrip
```

`spore create`, `spore run`, and `spore exec` run shell commands as
`/bin/sh -lc`. Use `-- <argv...>` when you need exact argv.

## Capture and resume

Capture a run when the command exits:

```bash
spore run --image docker.io/library/alpine:3.20 \
  --capture base.spore \
  'echo warmed > /var/tmp/example'
```

Run another command from that completed base spore, or attach to the captured
default session:

```bash
spore run --from base.spore 'cat /var/tmp/example'
spore run --from base.spore
```

If the captured session was still running with a guest terminal, reattach with
the same explicit terminal flags:

```bash
spore run -it --from live-shell.spore
```

Input attach fails closed when the captured session was not started with
interactive stdin or a terminal. The spore contains guest process and PTY
state, not the original host terminal connection.

`--from` resumes the spore and either attaches to the captured default session
or runs a fresh command through the restored exec agent. See
[docs/filesystem.md](docs/filesystem.md) for rootfs-backed writable state and
[docs/memory.md](docs/memory.md) for memory restore behavior.

## Fork and fan out

Fork an existing spore:

```bash
spore fork base.spore --count 100 --out forks
```

Children are named `000000`, `000001`, and so on. They share verified content
and get distinct generation metadata.

Resume forked children locally with prefixed output:

```bash
spore fanout forks --parallel --for 20s
```

See [docs/fanout.md](docs/fanout.md) for the child identity contract and
[docs/memory.md](docs/memory.md) for the memory chunk/backing contract.

## Pack and distribute

Pack a spore, optionally with forked children:

```bash
spore pack base.spore --children forks --out base.bundle
```

Unpack or pull one selected child before resume:

```bash
spore unpack base.bundle --child 000042 --out child.spore
spore resume child.spore
```

Remote pulls are digest-pinned:

```bash
spore pull s3://bucket/path/base.bundle@sha256:<bundle-digest> \
  --child 000042 \
  --out child.spore
```

`spore pack`, `spore unpack`, `spore push`, and `spore pull` carry the
manifest-selected memory, rootfs, and writable disk bytes. See
[docs/spore-format.md](docs/spore-format.md) and
[docs/filesystem.md](docs/filesystem.md) for the artifact contract.

## Named lifecycle

Named VM lifecycle is stable on supported HVF/KVM backends:

```bash
export SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo

spore create bench-1 --image docker.io/library/alpine:3.20
spore exec bench-1 'echo hi'
spore suspend bench-1 --out bench-1.spore --annotation captured=true
spore resume bench-1.spore --name bench-2
spore ps
spore rm bench-2
```

Create-time annotations and named lifecycle network policy can be passed as
flags or through a JSON options file:

```bash
spore create bench-net \
  --options @create-options.json
```

Machine callers can use global `--json` for structured lifecycle state. See
[docs/lifecycle.md](docs/lifecycle.md) for runtime layout, monitor jailing,
named live fork, and limits.

## Current scope

SporeVM supports one-shot runs, capture/resume, local fork/fan-out, rootfs-backed
runs, local and remote bundle materialization, explicit guest networking, and
named lifecycle on supported aarch64 HVF/KVM hosts.

Known limits: compatible host-class restore only, rootfs-bound writable disk
state only, diskless named live fork, and no hardened public-cloud
multi-tenant isolation claim. The detailed contracts are in the docs linked
above.

## Validation

Most local changes should start here:

```bash
mise run check
mise run smoke
```

Useful focused checks:

```bash
mise run smoke:run
mise run smoke:run-stdin
mise run smoke:run-tty
mise run smoke:run-attach
mise run smoke:run-capture
mise run smoke:lifecycle-tty
mise run smoke:rootfs-fanout
mise run smoke:writable-rootfs
mise run smoke:run-net-dns
mise run smoke:monitor-jail
mise run smoke:monitor-failure-modes
```

Repeatable benchmark runs live in [docs/benchmarks.md](docs/benchmarks.md).
Release notes and release-gate summaries live on
[GitHub releases](https://github.com/sporevm/sporevm/releases).

## Release

Releases are tag driven:

```bash
mise run release:prepare -- vX.Y.Z
mise run check
git commit -am "chore: Bump version to vX.Y.Z"
SPOREVM_RELEASE_VERSION=vX.Y.Z mise run release
```

`release:prepare` updates `src/version.zig`, the libspore shared-library
version, and pkg-config metadata together. `mise run release` runs local checks,
verifies the built CLI and pkg-config metadata match the target version, and
pushes the tag. The Buildkite tag build creates Linux ARM64 and macOS ARM64 CLI
archives plus matching `libspore` archives, writes `checksums.txt`, and
publishes the GitHub release. Use `mise run release:snapshot` to build release
archives locally without publishing.

Buildkite release builds should be triggered by GitHub `push` events only. Do
not subscribe the Buildkite webhook to GitHub `create` events, or a pushed tag
can create duplicate tag builds.

## Security

Read [SECURITY.md](SECURITY.md) before changing virtqueue parsing, manifest or
bundle decoding, guest memory access, rootfs materialization, or monitor control
paths.

## License

[MIT](LICENSE)
