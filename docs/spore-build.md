# Spore Build

`spore build` executes a supported Dockerfile directly into SporeVM's local
rootfs store. It produces a local Spore image rather than Docker layers or a
pushable OCI image.

```bash
spore build \
  -t local/app:dev \
  --platform linux/arm64 \
  .

spore run --image local/app:dev --pull=never -- /usr/local/bin/app
```

The builder deliberately implements a bounded Dockerfile subset. A feature is
accepted only when SporeVM can match the selected Dockerfile frontend's final
filesystem and OCI runtime configuration with sound cache invalidation.
Unsupported instructions, flags, values, and combinations fail during
full-file planning before a base fetch, remote `ADD`, cache mutation, or guest
execution begins.

## Command Line

`-t` is required and must name a mutable `local/<name>:<tag>` ref. The build
context defaults to `.` and `-f` defaults to `<context>/Dockerfile`.

```text
spore build [options] CONTEXT

  -t, --tag REF                  Local image ref to update
  -f, --file PATH                Dockerfile path
  --platform linux/arm64         Target platform
  --target STAGE                 Selected stage
  --build-context NAME=oci-layout://PATH
                                  Named OCI-layout base
  --build-arg KEY=VALUE          Build argument
  --network spore|none           RUN network policy
  --no-cache                     Bypass Dockerfile step-cache reads
  --memory SIZE                  Build VM memory
  --vcpus COUNT                  Build VM vCPUs, from 1 through 8
  --timeout DURATION             Per-instruction timeout
  --ulimit nofile=SOFT[:HARD]    RUN open-file limit
  --mkfs PATH                    mkfs helper for OCI imports
  --debugfs PATH                 debugfs helper for OCI imports
```

The only target platform is `linux/arm64`. `--network spore` is the default;
use `--network none` for builds whose `RUN` steps require no network. Timeout
applies independently to each Dockerfile instruction. Memory, vCPU count, and
`nofile` enter RUN cache identity because a command can observe them; timeout
does not.

`--build-context` is repeatable and currently accepts only named OCI layouts.
For example, `--build-context base=oci-layout:///tmp/base.oci` makes `FROM base`
resolve through that layout. Ordinary registry refs, local image refs, earlier
stages, and `scratch` remain available through `FROM` without this option.

## Dockerfile Contract

The parser accepts standard `docker/dockerfile:1` syntax directives, including
`1.x` spellings and digest-pinned `1@...` spellings, plus `# escape=\\` and
``# escape=` ``. A directive selects syntax parsing; it does not imply that
every feature from that frontend version is implemented.

| Instruction | Current support |
| --- | --- |
| `FROM` | Multi-stage `FROM ... AS`, `--platform=linux/arm64`, `scratch`, public registry images, local images, named OCI-layout contexts, and inheritance from an earlier stage. Only the selected target's reachable stage closure executes. |
| `ARG`, `ENV` | Global and stage arguments, repeated `--build-arg`, automatic platform arguments, and bounded `$NAME`, `${NAME}`, `${NAME:-word}`, `${NAME-word}`, `${NAME:+word}`, and `${NAME+word}` expansion. Unsupported modifiers fail closed. |
| `WORKDIR` | Absolute and parent-relative paths with Docker-compatible resolution and builder expansion. |
| `CMD`, `ENTRYPOINT` | Shell and JSON-array forms, including inheritance into later stages and publication in the final image config. |
| `RUN` | Shell form, bounded JSON-array exec form, and one simple unquoted non-chomping shell heredoc. Exec form performs Docker-compatible `PATH` lookup but no implicit shell or variable expansion. |
| `COPY` | Context files, directories, supported globs, ordered `.dockerignore`, one simple heredoc source, literal cross-stage or named-input sources, cross-stage `--link[=true|false]`, and context `--parents[=true|false]`. |
| `ADD` | One public HTTPS URL and one destination, with optional numeric `--chmod=0...07777`. The response is treated as an opaque regular file; it is not unpacked. |

Context `COPY --parents` preserves each selected source's cleaned root-relative
parent path. It cannot be combined with `--from`, `--link`, heredocs, an
internal `/./` pivot, or the context-root operands `.` and `./`. Context
`COPY --link` remains unsupported; link policy is accepted only with
`COPY --from`.

Context `COPY` applies source modes and root ownership. Cross-stage `COPY`
preserves supported source ownership and metadata. `COPY --chown` and
`COPY --chmod` are not implemented. Public HTTPS `ADD --chmod` is the one
current numeric-mode exception.

Shell-form `RUN` uses `/bin/sh -c`. JSON-array `RUN` executes the exact argv
after bounded `PATH` selection when argv zero contains no slash. The shared
guest resolver accepts at most 250 `PATH` bytes, 64 entries, and a 511-byte
candidate plus its terminator. Missing and empty `PATH` do not search the
working directory. Relative entries are skipped unless they name an executable,
in which case lookup fails closed; absolute traversal remains confined by the
operation-owned guest sandbox. A missing shell or executable fails that
instruction, and execution never falls through to a later binary after
selecting one.

Executor-backed instructions require an inherited OCI `User` that selects the
root user and an optional root group. Other users and groups fail closed because
the build guest cannot switch credentials yet.

## RUN Mounts

The current mount surface is deliberately narrow:

- `RUN --mount=type=cache,target=PATH[,id=ID][,sharing=shared|locked]` accepts
  at most eight mounts. An omitted ID derives from the cleaned target. Both
  sharing modes are conservatively serialized by SporeVM's host-local cache
  locks. Cache contents survive failed RUNs and later builds but never enter a
  rootfs checkpoint or image.
- `RUN --mount=type=bind,source=FILE,target=PATH` accepts only a literal regular
  file from the immutable build context, read-only, in ordinary shell form.
  Directories, symlinks, globs, writable binds, and stage, image, or named
  context sources fail closed.
- One exact `RUN --mount=type=ssh` declaration is accepted only as an
  optional-absent compatibility form. It sets the BuildKit-compatible
  `SSH_AUTH_SOCK` value when needed but creates no socket and forwards no
  credential. Options, duplicate declarations, required sockets, and actual
  SSH inputs are unsupported.

Secret mounts, writable bind mounts, host paths, devices, the Docker socket,
and privileged or insecure RUN modes are outside the builder contract.

## Remote ADD

Remote `ADD` accepts public HTTPS only. The host validates every requested and
redirect target as public, applies strict redirect and response bounds, stages
the bytes privately, and hashes their actual content before cache lookup. The
same requested URL with changed bytes is therefore a cache miss.

A build accepts at most 64 remote ADD instructions, 1 GiB of combined response
bodies, and ten minutes of combined fetch time or the smaller build timeout.
HTTP, credentials, Git, remote archives, `--checksum`, `--chown`, symbolic
modes, and unpacking remain unsupported.

## Execution And Cache Model

SporeVM parses and plans the complete Dockerfile before execution, then resolves
the selected target's reachable stages and external inputs. Unreachable stages
do not execute or fetch their bases.

Before the first executor-backed instruction, a supported journal-less rootfs
smaller than 16 GiB is prepared once to exactly 16 GiB. A typed `PREPARE`
record makes that infrastructure normalization reusable across Dockerfiles and
under `--no-cache`; images already at or above 16 GiB keep their exact size.
There is no build-capacity flag or recursive growth rule.

An uncached suffix runs in one persistent build VM. RUN, COPY, ADD, and WORKDIR
execute in Dockerfile order. After each successful filesystem step, SporeVM
freezes the guest filesystem, drains virtio-blk, seals changed 64 KiB chunks,
publishes the complete rootfs index, and then records the step result. A failed
or timed-out instruction publishes no result for that instruction and never
updates the destination ref.

Every RUN executes in an operation-owned PID and mount view with scoped procfs,
a fresh minimal `/dev`, protected kernel paths, cgroup device controls, and
seccomp restrictions around host-control surfaces. Cleanup must complete before
the step result can be published. The full isolation and parser boundaries live
in [SECURITY.md](../SECURITY.md).

The final local image identity binds the selected rootfs index and canonical OCI
runtime configuration. `--no-cache` bypasses Dockerfile step-record reads but
continues to write new records and reuse rootfs imports, `PREPARE`, and other
infrastructure caches. Build caches are host-local; there is no remote shared
cache, Docker layer export, OCI registry push, or BuildKit cache import/export.

The durable storage, cache publication, mount lifetime, and garbage-collection
contracts live in [Filesystem And Root Disk Contract](filesystem.md). Rootfs
imports, local refs, and automatic capacity behavior are covered in
[Rootfs Images](rootfs.md).

## Unsupported Instructions

The current parser rejects instructions outside the table above, including
`LABEL`, `USER`, `VOLUME`, `EXPOSE`, `HEALTHCHECK`, `ONBUILD`, `SHELL`, and
`STOPSIGNAL`. It also rejects custom frontend images, labs syntax, Windows or
foreign-architecture stages, arbitrary frontend plugins, credential-bearing
SSH, remote Git inputs, and OCI layer or registry output.

This is a fail-closed compatibility boundary, not a promise to accept every
Dockerfile accepted by BuildKit. Support grows from concrete public workload
failures with differential filesystem, configuration, cache, and security
coverage.

## Validation

Run the maintained Docker/BuildKit differential fixtures with:

```bash
mise run test:spore-build-conformance
```

The complete unit and parser/fuzz graph runs under `mise run test`. Real-hardware
capacity and publication checks use `mise run smoke:build-rootfs-capacity` and
`mise run smoke:build-publication` on ARM64 HVF and KVM hosts.
