<p align="left">
  <img src="assets/sporevm-mark-bounded.png" alt="SporeVM" width="160">
</p>

# SporeVM

[![Buildkite](https://badge.buildkite.com/43af213c90bb781b385d58fc664e5ee8f1b99502f66102e53a.svg?branch=main)](https://buildkite.com/buildkite/sporevm)
[![Release](https://img.shields.io/github/v/release/sporevm/sporevm?sort=semver)](https://github.com/sporevm/sporevm/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](mise.toml)

SporeVM is a small virtual machine monitor for saving and forking Linux
microVM state.

A spore is sealed VM state with normalized machine state, device state,
verified memory chunks, optional rootfs state, and a platform contract that
fails closed when a host cannot restore it honestly.

The useful shape of the lifecycle is:

1. Start a runtime once.
2. Warm it up until the expensive boring work is done.
3. Save it at a clean point.
4. Fork cheap child spores.
5. Attach the children on compatible hosts without copying all RAM for
   every child.

## Platforms

| Host | Current support |
| --- | --- |
| macOS/ARM64 + HVF | Mature full lifecycle |
| Linux/ARM64 + KVM | Mature full lifecycle |
| Linux/AMD64 + KVM | Experimental fresh workloads; no saved state |

The full lifecycle includes run, save, attach, restore, fork, fan-out, rootfs,
networking, build, named VMs, and checkpoint push and pull.
SporeVM 1.0 expects spores to restore on the same backend and compatible host
class they were saved for: KVM/aarch64 to KVM/aarch64, or Apple Silicon HVF to
Apple Silicon HVF. The repo still keeps KVM/HVF restore checks because they
catch backend-specific state leaking into the spore format, but users should
not plan distribution around moving one running machine between those
hypervisors.

The Linux/AMD64 profile is deliberately narrower and frozen. It uses the
managed kernel and embedded minimal exec initrd with one vCPU and exactly
512 MiB of memory. Fresh one-shot runs and named VMs (`spore vm create`,
`exec`, and `rm`) support native `linux/amd64` OCI images, explicit rootfs
inputs, networking, and one-shot image commit, and `spore build` builds
`linux/amd64` natively. Capture, save, restore, resume, fork, fan-out,
multi-vCPU, and elastic memory are unavailable; saved-state options fail
closed. The profile needs an Intel host whose KVM provides the
`sporevm-x86_64-v0` CPU profile, including TSC scaling to the 3 GHz guest
clock; other hosts fail with `IncompatibleCpuProfile` and the mismatched fact,
and `spore system info` reports `cpu_profile_incompatible`. Release archives
are ARM64-only; build from source for this profile. SporeVM never emulates
another instruction set.

## Design details

- [docs/spore-format.md](docs/spore-format.md): manifest and invariant
  contract.
- [docs/state-portability.md](docs/state-portability.md): KVM/HVF state mapping
  and fail-closed restore matrix.
- [docs/memory.md](docs/memory.md): memory chunks, local backing, and dirty
  tracking.
- [docs/filesystem.md](docs/filesystem.md): rootfs CAS and writable root disk
  layers.
- [docs/rootfs.md](docs/rootfs.md): OCI image and rootfs CLI workflows.
- [docs/spore-build.md](docs/spore-build.md): native Dockerfile builder usage and
  compatibility boundary.
- [docs/docker.md](docs/docker.md): prepare and run Docker inside a spore.
- [docs/fanout.md](docs/fanout.md): fork identity and fan-out behavior.
- [docs/networking.md](docs/networking.md): SporeVM-managed networking.
- [docs/lifecycle.md](docs/lifecycle.md): named VM lifecycle.
- [docs/automation.md](docs/automation.md): versioned `--json` results, stream
  completion, and stable failure classification for programs that drive
  `spore`.

## Install

If you use [mise](https://mise.jdx.dev), install it globally:

```bash
mise use -g github:sporevm/sporevm@latest
spore --version
```

Or download the Linux ARM64 or macOS ARM64 archive from
[GitHub releases](https://github.com/sporevm/sporevm/releases/latest):

```bash
asset=spore_Darwin_arm64 # or spore_Linux_arm64
tar -xzf "$asset.tar.gz"
"$asset/bin/spore" --version
```

Use `spore_Linux_arm64` on Linux. Add `$asset/bin` to `PATH`, or move the
extracted directory wherever you keep standalone tools. For Linux/AMD64, see
[Platforms](#platforms).

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
`mise run smoke core` boots real VMs on Apple Silicon or Linux ARM64 with KVM;
see [Validation](#validation).

For local iteration:

```bash
mise run build
zig-out/bin/spore --version
```

## Run a command

Run one command in a throwaway VM:

```bash
spore run --shell 'echo hi'
```

`spore run` uses the managed SporeVM run kernel and the embedded minimal exec
initrd. The embedded initrd contains the guest agent plus a small Toybox
shell environment for basic commands such as `echo`, `cat`, `printf`, `pwd`,
and `uname`. Use `--image` or `--rootfs` for distro behavior, package
managers, or commands outside that bounded set.

Exact argv after `--` still uses the path you provide without guest PATH
lookup:

```bash
spore run -- /bin/echo hi
```

Set command environment with repeatable `--env`. `KEY=VALUE` sets a value;
`KEY` copies it from the host `spore` process environment:

```bash
spore run --env SPORE_TEST_ENV=ok -- /usr/bin/env
SPORE_TEST_ENV=ok spore run --env SPORE_TEST_ENV -- /usr/bin/env
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
rootfs cache. `--inject` is rejected with `--save-checkpoint` and `--checkpoint` because file
persistence would otherwise be ambiguous. Disk-only `--commit-image` allows
injection; the tmpfs file remains transient unless the guest copies it onto the
root disk:

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
spore run --kernel Image --initrd root.cpio -- /bin/true
```

Use `spore --debug run ...` for verbose VMM setup and restore logs.

## Run from an OCI image

Build or reuse a cached ext4 rootfs from an OCI reference, then run a shell
command inside it:

```bash
spore run --image docker.io/library/alpine:3.20 --shell 'echo hi'
```

`--image` applies OCI `Env`, `WorkingDir`, `Entrypoint`, and `Cmd` when present.
With no command it runs `Entrypoint` plus `Cmd`; an explicit command replaces
`Cmd` but follows `Entrypoint`. Use `--entrypoint PATH` to replace the image
entrypoint while retaining those command rules. OCI `User` must select root
until guest credential switching is supported. Shell commands run as
`/bin/sh -lc` in the guest. Use `-- <argv...>` when you need exact argv.

Commit the successful run's root disk as another local image when setup is more
naturally expressed as a command than a Dockerfile:

```bash
spore run \
  --image docker.io/library/alpine:3.20 \
  --commit-image local/alpine-with-git:dev \
  -- /bin/sh -lc 'apk add --no-cache git'
```

Commit is disk-only and leaves the destination ref unchanged unless the guest
command and publication both succeed. Save one warm machine from the resulting
image, then use offline `spore checkpoint fork` for low-latency fan-out.
Add `--disk-size 20gb` when preparation needs a larger root disk; commit grows
the private sparse head with known-zero chunks and asks the managed initrd to
grow ext4 directly. The selected image needs no `resize2fs` or e2fsprogs for
that growth.
Explicit larger disks remain subject to the current 64 MiB canonical-index
limit: a sufficiently dense disk above about 30.62 GiB will fail a later
snapshot or commit closed. Prefer the smallest required size; the 20 GiB
example remains encodable even when fully populated.

Export a registry image's root filesystem as a reusable ext4 file:

```bash
spore image export-rootfs docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

spore run --rootfs alpine.ext4 --shell 'echo hi'
```

See [docs/rootfs.md](docs/rootfs.md) for cache behavior, local OCI layout
imports, and rootfs pruning.

## Networked runs

SporeVM-managed networking is explicit:

```bash
spore run --net --allow-host example.com \
  --image docker.io/library/alpine:3.20 \
  -- wget -qO- https://example.com
```

Plain `--net` allows public egress outside the built-in hard floor;
`--allow-host` or `--allow-cidr` restrict it to those hosts or CIDRs. Saved
network policy is replayed by `spore run --checkpoint`; omit `--net` and allow flags
on run-from commands.

Use `--forward 127.0.0.1:HOST_PORT:GUEST_PORT` to expose one live guest TCP
port on host loopback while the run or named VM monitor is alive.

See [docs/networking.md](docs/networking.md) for policy, bound-service,
port-forward, and restore or attach limits.

## Fork a live VM

Start a named VM with a running process:

```bash
spore vm create counter --image docker.io/library/alpine:3.20 \
  --shell 'i=0; while true; do echo "$i" > /tick; i=$((i + 1)); sleep 1; done'
```

Fork it while that process is still running:

```bash
spore vm fork counter --count 2 --name-prefix child
```

Both children keep running from the fork point:

```bash
spore vm exec child-0 --shell 'cat /tick; sleep 1; cat /tick'
spore vm exec child-1 --shell 'cat /tick; sleep 1; cat /tick'
```

Named exec can also be interactive when you opt in to input or a terminal:

```bash
printf 'hello\n' | spore vm exec -i child-0 -- /bin/cat
spore vm exec -it child-0 -- /bin/sh
```

Copy explicit files or directories into or out of a named VM:

```bash
spore vm copy-in child-0 ./local.txt /tmp/local.txt
spore vm copy-out child-0 /tmp/local.txt ./roundtrip.txt
spore vm copy-in child-0 ./src /tmp/src
spore vm copy-out child-0 /tmp/src ./src-roundtrip
```

`spore vm create`, `spore run`, and `spore vm exec` use explicit `--shell STRING` as
`/bin/sh -lc`. Use `-- <argv...>` when you need exact argv.

## Save and attach

Save a run when the command exits:

```bash
spore run --image docker.io/library/alpine:3.20 \
  --save-checkpoint base.spore \
  --shell 'echo warmed > /var/tmp/example'
```

The `--save-checkpoint` target must not already exist; SporeVM creates the output
directory before the backend starts writing snapshot files.

Run another command from that completed base spore, or attach to a saved
session:

```bash
spore run --checkpoint base.spore --shell 'cat /var/tmp/example'
spore checkpoint resume live-shell.spore
```

If the saved session was still running with a guest terminal, reattach with
the same explicit terminal flags:

```bash
spore checkpoint resume -it live-shell.spore
```

Input attach fails closed when the saved session was not started with
interactive stdin or a terminal. The spore contains guest process and PTY
state, not the original host terminal connection.

`--checkpoint` restores the spore and runs a fresh command through the restored exec
agent. `checkpoint resume` restores a new throwaway VM and resumes its saved session;
it does not connect to a live named VM. Use `vm restore NAME --checkpoint DIR`
to keep a restored named machine without attaching saved streams. See
[docs/filesystem.md](docs/filesystem.md) for rootfs-backed writable state and
[docs/memory.md](docs/memory.md) for memory restore behavior.
For one-shot child runs with externally assigned shard identity, add
`--generation generation.json` to `spore run --checkpoint`; the JSON is published to
the guest before the command starts.

## Fork and fan out

Fork an existing checkpoint:

```bash
spore checkpoint fork base.spore --count 100 --output forks
```

Children are named `000000`, `000001`, and so on. They share verified content
and get distinct generation metadata.

Attach forked children locally with prefixed output:

```bash
spore checkpoint fanout forks --for 20s
```

See [docs/fanout.md](docs/fanout.md) for the child identity contract and
[docs/memory.md](docs/memory.md) for the memory chunk/backing contract.

## Distribute

To move a saved spore between hosts, push it to an
[image store](docs/image-format.md#spores) and pull it on the other host:

```bash
spore checkpoint push base.spore --to s3://bucket/spores/base
spore checkpoint pull s3://bucket/spores/base --output base.spore
spore run --checkpoint base.spore -- ./bin/test
```

See
[docs/spore-format.md](docs/spore-format.md) and
[docs/filesystem.md](docs/filesystem.md) for the artifact contract.

## Named lifecycle

The complete named VM lifecycle is stable on ARM64 HVF/KVM hosts:

```bash
export SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo

spore vm create bench-1 --image docker.io/library/alpine:3.20
spore vm logs bench-1 --initial
spore vm exec bench-1 --shell 'echo hi'
spore vm save bench-1 --output bench-1.spore --stop --annotation saved=true
spore vm restore bench-2 --checkpoint bench-1.spore
spore vm ls
spore vm rm bench-2
```

Use `spore checkpoint rm DIR` to delete saved state; `spore system gc --force`
then reclaims storage nothing else references.
`spore vm rm NAME` stops the live monitor and deletes runtime state without
touching checkpoints or images.

Create-time annotations and named lifecycle network policy can be passed as
flags or through a JSON options file:

```bash
spore vm create bench-net \
  --options @create-options.json
```

Create retains bounded initial-command output by default; use
`spore vm logs NAME --initial` to retrieve it after create returns. It is not
exec history or a following log. Machine callers can use global `--json`
for structured lifecycle state. See [docs/lifecycle.md](docs/lifecycle.md) for
runtime layout, monitor jailing, named live fork, and limits.

## Current scope

SporeVM supports one-shot runs, save/attach, local fork/fan-out, rootfs-backed
runs, checkpoint push and pull through image stores, explicit guest
networking, and named lifecycle on supported arm64 HVF/KVM hosts. Linux/AMD64
is narrower; see [Platforms](#platforms).

Known limits: compatible host-class restore only, rootfs-bound writable disk
state only, diskless named live fork, and no hardened public-cloud
multi-tenant isolation claim. The detailed contracts are in the docs linked
above.

## Repository layout

- `src/`: SporeVM implementation, including backend-specific and shared device
  model code.
- `guest/`: source for guest initrd assets embedded by the build.
- `test/`: unit smoke fixtures and product smoke tests.
- `scripts/`: CI, release, benchmark, kernel asset, and internal helper
  automation.

## Validation

Most local changes should start here:

```bash
mise run check
mise run smoke core
```

`mise run smoke core` builds `spore` with the shipped ReleaseSafe settings and
`-Dsmoke-helpers`, which adds the guest helper binaries the scripts run, then
boots real VMs through run, signal save, fork, named disk forks with save,
restore, prune and GC, the named lifecycle, copy, the monitor jail,
networking, lazy image-store runs, and ext4 writes after the guest evicts its
block-allocator cache. CI runs it on every commit on Linux ARM64 (KVM) and macOS (HVF).
`mise run smoke full` adds the other aarch64 scripts in `test/smoke/`. The
suite prints one line per script and keeps each script's log under
`zig-cache/smoke/`. `mise run smoke` also takes one script path without `.sh`,
such as `mise run smoke run/tty`; on Linux x86-64 KVM hosts, `mise run smoke
x86/run` and `mise run smoke x86/build` run the x86-64 smokes. Each script also
runs on its own against such a build in `zig-out/bin/spore` (or `SPORE_BIN`),
for example `test/smoke/run/tty.sh`.

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

`release:prepare` updates the authoritative version in `src/version.zig`; the
CLI derives its version from it. `mise run release` runs local checks, verifies
the built CLI matches the target version, and pushes the tag. The Buildkite tag
build creates Linux ARM64 and macOS ARM64 CLI archives, writes
`checksums.txt`, and publishes the GitHub release. Use
`mise run release:snapshot` to build release archives locally without
publishing.

Buildkite release builds should be triggered by GitHub `push` events only. Do
not subscribe the Buildkite webhook to GitHub `create` events, or a pushed tag
can create duplicate tag builds.

## Security

Read [SECURITY.md](SECURITY.md) before changing virtqueue parsing, manifest
decoding, guest memory access, rootfs materialization, or monitor control
paths.

## License

[MIT](LICENSE)
