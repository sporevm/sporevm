---
status: active
last_reviewed: 2026-06-16
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - README.md
  - src/local_paths.zig
  - src/run.zig
  - scripts/make-minimal-exec-initrd.sh
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/local-image-ref-cache.md
---

# Named VM Lifecycle Plan

## Summary

SporeVM needs a persistent lifecycle surface between one-shot `spore run` and
sealed spore artifacts. The first useful version should start a named VM, keep
it alive in a per-VM monitor process, execute multiple commands over the guest
agent, and remove the VM without requiring a central always-on daemon.

`spore run` remains the one-shot convenience command:

```console
spore run --image docker.io/library/node:22-alpine -- /bin/sh -lc 'node -v'
```

The lifecycle surface uses top-level commands and treats the target as a named
running VM:

```console
spore create bench-1 --image docker.io/library/node:22-alpine
spore exec bench-1 -- /bin/sh -lc 'node -v'
spore rm bench-1
```

This keeps the public nouns separated:

- **VM**: a currently running guest owned by a local monitor process.
- **monitor**: the long-lived host process that owns one VM and its devices.
- **spore**: a sealed checkpoint artifact used for suspend, fork, fan-out, and
  restore.
- **machine state**: the low-level architectural state stored inside a spore.

Avoid `sandbox` in the core CLI. It implies policy, egress, secrets, mounts,
workspace semantics, and product-level isolation behavior that SporeVM does not
own. Cleanroom and other consumers can expose sandbox language above SporeVM.

## Problem

`spore run` now proves the boot/exec path and can execute explicit argv from a
minimal initrd, a read-only rootfs, or a cached OCI-derived rootfs. It still
boots a throwaway VM, sends one command request, and exits.

That shape cannot support workflows that need a live guest identity across
multiple commands. A simple lifecycle timing script is the concrete pressure:
start a timer, create a VM, run an identity probe, run `node -v`, then remove
the VM outside the timed section. Running each command through separate
`spore run` invocations would measure the wrong thing and hide reuse bugs.

Returning from `create` while the VM remains alive also requires a long-lived
owner for the hypervisor VM, vCPU threads, virtio devices, rootfs fd, console
log, and vsock state. The right constraint is no central daemon in the first
slice, not no long-lived process at all.

## Goals

- Keep `spore run` as the durable one-shot boot/exec/status convenience.
- Add a named running-VM lifecycle:

  ```console
  spore create NAME [boot/input options]
  spore exec NAME -- <argv...>
  spore rm NAME
  spore ls
  ```

- Use one per-VM monitor process. No central daemon is required for create,
  exec, or remove.
- Use a per-VM Unix control socket with newline-delimited JSON.
- Keep the public lifecycle backend-neutral across HVF and KVM.
- Preserve the foundation ownership boundary: SporeVM owns the VMM, monitor,
  device model, spore format, and local rootfs materialization utility;
  consumers own sandbox policy, secrets, egress, scheduling, and workload
  semantics.
- Make the first implementation small enough to smoke locally on HVF and later
  repeat on KVM.
- Add a local timing script that measures the named-VM lifecycle without making
  any external benchmark harness a dependency of this repository.

## Non-Goals

- No `spore sandbox` core command.
- No central `spore daemon` in the first lifecycle slice. The daemon remains a
  later chunk-cache and peer-exchange service from the foundation plan.
- No OCI Entrypoint, Cmd, User, Env, or Workdir semantics in the first slice.
- No implicit shell wrapping in `spore exec`; callers that want command-string
  behavior can run `/bin/sh -lc ...` explicitly.
- No stdin streaming, TTY, interactive terminal, or unbounded output streaming
  in the first slice.
- No multi-vCPU lifecycle support until the underlying run path supports it.
- No writable cached OCI rootfs. Writable ephemeral directories are mounted as
  tmpfs where needed.
- No disk capture in the spore manifest as part of create/exec. Disk-backed
  suspend continues to require an unchanged backing disk until disk manifests
  land in the foundation plan.

## Target Model

### User-Facing Commands

The common path has no noun:

```console
spore create bench-1 --image docker.io/library/alpine:3.20
spore exec bench-1 -- /bin/echo hi
spore exec bench-1 -- /bin/sh -lc 'cat /proc/sys/kernel/random/boot_id'
spore rm bench-1
```

`spore run` remains sugar over a private create/exec/remove sequence once the
lifecycle exists, but its public behavior stays one-shot:

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

Future suspend/resume extends the same named-VM model:

```console
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
```

### Runtime Directory

Live VM state is runtime state, not cache state. It should live under an
operator-controlled runtime directory:

```text
$SPOREVM_RUNTIME_DIR/vms/<name>/
  control.sock
  pid
  spec.json
  ready.json
  create-timing.json
  monitor-timing.json
  console.log
```

Resolution order:

1. `SPOREVM_RUNTIME_DIR`
2. `$XDG_RUNTIME_DIR/sporevm`
3. a platform temp fallback such as `$TMPDIR/sporevm-$UID`, created `0700`

The path-selection logic is shared through `src/local_paths.zig`; lifecycle
still owns private-directory validation for live VM state.

Do not store live sockets under the rootfs cache or a persistent home cache.
Runtime directories must be private to the current user. VM names are not path
fragments: reject names with `/`, empty names, overly long names, and names
outside a conservative `[A-Za-z0-9._-]` set.

### Per-VM Monitor

`spore create` resolves boot assets and workload inputs, creates the runtime
directory, then spawns a detached monitor:

```console
spore monitor --runtime-dir ... --name bench-1 --spec spec.json
```

`spore monitor` is an internal command. It owns:

- the hypervisor VM and vCPU threads;
- virtio device state;
- the rootfs fd if one is attached;
- the guest vsock path;
- the console log;
- the control socket.

`spore create` waits for the monitor pid and control socket metadata to become
ready before returning. The current minimal slice uses `ready.json` as the
synchronization point; a stronger guest-agent readiness handshake can replace
that once rootfs/image lifecycle work needs it.

### Control Protocol

The monitor listens on `control.sock` for local newline-delimited JSON. The
first request set should be intentionally small:

```json
{"type":"exec","argv":["/bin/echo","hi"],"timeout_ms":30000}
{"type":"stop"}
{"type":"status"}
```

The `exec` response should reuse the `spore run --json` result shape where
practical: exit code, bounded stdout/stderr, truncation flags, and timing
fields. That keeps the one-shot and persistent paths aligned.

### Backend Shape

The current `run` implementation drives HVF or KVM until one `exec_probe`
completes. Lifecycle monitor work should split that behavior into two layers:

- backend-neutral lifecycle orchestration that owns a monitor control loop;
- backend-specific run loops that can continue after one vsock request and
  stop only on monitor shutdown or backend failure.

The guest agent already accepts multiple vsock connections in a loop, so the
first persistent exec slice should focus on host-side monitor ownership rather
than redesigning the guest protocol.

## Safety And Invariants

- `spore run` output and exit-code behavior must not regress while lifecycle
  work lands.
- A VM monitor is the only owner of its VM. CLI commands communicate through
  the control socket; they do not reach into backend internals.
- Runtime directories are `0700`; control sockets are only accessible by the
  owning user.
- Stale runtime directories fail closed unless the recorded monitor pid is dead
  and the user explicitly removes or recreates the VM.
- `spore rm` asks the monitor to stop first, waits with a bounded timeout, and
  only then escalates to process termination for a monitor owned by the same
  runtime directory.
- Monitor crashes are visible: `spore exec` reports that the VM is gone rather
  than silently creating a replacement.
- Cached OCI rootfs images remain read-only. Writable guest scratch space is
  tmpfs and not persisted into the cache.
- Unsupported backend/runtime combinations fail before starting a monitor.
- The protocol is local-only in the first slice. No TCP control socket, no
  remote API, and no auth story beyond local filesystem permissions.

## Current State

- `spore run` can resolve default run assets, attach read-only rootfs images,
  build/reuse cached rootfs images from OCI refs, and execute one argv request.
- The minimal exec initrd guest agent listens on vsock, uses session ids to make
  retried starts idempotent, and allows fresh session ids to run sequential
  commands in one boot.
- `spore create`, `spore exec`, `spore rm`, and `spore ls` have the first
  runtime registry and metadata shape.
- HVF can keep one minimal-initrd VM alive in an internal monitor process and
  attach one host-initiated vsock stream per `spore exec`.
- The lifecycle monitor assigns a fresh guest session id per `spore exec`, so
  two commands can run against one boot while same-session reconnects still
  attach to the existing command result instead of executing twice.
- KVM still treats the exec stream as a one-shot probe for lifecycle purposes.
  Monitor mode fails explicitly on KVM until that backend has a real wake path
  for host-attached streams.
- `spore create --rootfs PATH` and `spore create --image REF` reuse the same
  read-only rootfs materialization path as `spore run`.
- `spore suspend NAME --out DIR` and `spore resume DIR --name NAME` work for
  diskless lifecycle VMs on local HVF. Disk-backed lifecycle suspend/resume
  fails closed until disk identity and disk manifests are explicit.

## Delivery Strategy

### Slice A: Runtime Registry And CLI Shape

Status: landed.

Scope:

- Add command parsing for `create`, `exec`, `rm`, and `ls`.
- Add runtime-directory resolution and VM name validation.
- Add runtime metadata helpers for `spec.json`, `ready.json`, `pid`, and stale
  directory detection.
- Add tests for path resolution, name validation, and stale-state behavior.
- Keep registry directories private to the current user and reject insecure
  existing runtime paths.

Done when:

```console
spore create --help
spore exec --help
spore rm --help
spore ls
```

have the intended shape, and malformed names or unsafe runtime paths fail
closed before any backend work starts.

### Slice B: Minimal Initrd Monitor

Status: complete for local HVF; KVM wake support remains a follow-up.

Scope:

- Add the internal `spore monitor` command.
- Refactor backend run loops enough for the monitor to keep one VM alive after
  the first command completes.
- Implement `spore create NAME` with default kernel/initrd assets only.
- Implement `spore exec NAME -- <argv...>` over the local control socket.
- Implement `spore rm NAME`.
- Keep output bounded and reuse the existing run result framing.
- Keep `--rootfs` and `--image` rejected until Slice C.
- Fail KVM monitor mode explicitly until KVM has a real control-thread wake
  path for `KVM_RUN`.

Done when, on HVF locally:

```console
spore create bench-1
spore exec bench-1 -- /bin/writeout
spore exec bench-1 -- /bin/true
spore rm bench-1
```

uses one guest boot and two successful command requests. KVM repeats the same
smoke once an aarch64 KVM host is available.

Validated locally:

```console
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-b spore create bench-1 --timeout-ms 30000
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-b spore exec bench-1 -- /bin/writeout
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-b spore ls
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-b spore rm bench-1
```

The stale-monitor smoke kills the recorded monitor pid after readiness and
confirms `spore exec` reports `VM is not ready ... (stale)` instead of dumping a
runtime stack trace.

### Slice C: Rootfs And Direct Image Create

Status: complete for local HVF.

Scope:

- Add `--rootfs PATH` and `--image REF` to `spore create`.
- Reuse the direct image cache from `spore run --image`.
- Ensure required writable scratch directories exist for common benchmark
  probes, especially `/tmp` and `/var/tmp`, without mutating cached rootfs
  images.
- Keep rootfs mounted read-only.

Done when:

```console
spore create bench-alpine --image docker.io/library/alpine:3.20
spore exec bench-alpine -- /bin/echo hi
spore rm bench-alpine
```

works from a warm rootfs cache and from an empty isolated cache directory.

Validated locally with an isolated `/tmp/sporevm-slice-c-cache`:

```console
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c \
SPOREVM_ROOTFS_CACHE_DIR=/tmp/sporevm-slice-c-cache \
spore create bench-alpine --image docker.io/library/alpine:3.20 --timeout-ms 60000
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore exec bench-alpine -- /bin/echo hi
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore rm bench-alpine

SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c \
spore create bench-rootfs --rootfs /tmp/sporevm-slice-c-cache/<cache-key>.ext4 --timeout-ms 60000
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore exec bench-rootfs -- /bin/echo rootfs-ok
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore rm bench-rootfs

SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c \
SPOREVM_ROOTFS_CACHE_DIR=/tmp/sporevm-slice-c-cache \
spore create bench-warm --image docker.io/library/alpine:3.20 --timeout-ms 60000
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore exec bench-warm -- /bin/echo warm-ok
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-c spore rm bench-warm
```

### Slice D: Local Lifecycle Timing Script

Status: complete for local HVF.

Scope:

- Add `scripts/benchmark-sporevm-lifecycle.sh`.
- Measure the user-visible lifecycle boundary:

  ```console
  start timer
  spore create NAME --image docker.io/library/node:22-alpine
  spore exec NAME -- /bin/sh -lc '<identity probe>'
  spore exec NAME -- /bin/sh -lc 'node -v'
  stop timer
  spore rm NAME
  ```

- Keep cleanup outside the timed section.
- Prefer a digest-pinned `linux/arm64` Node image for stable comparisons. The
  local smoke uses the tag-resolved `docker.io/library/node:22-alpine` image
  because plain `node:22` currently hits the rootfs builder's
  `CaseCollisionPath` guard.
- Support an isolated warm-cache run first. Add cold-cache and concurrent modes
  only after the single-VM lifecycle is stable.
- Write JSONL with per-iteration `create_to_node_ms`, command exit status, and
  enough phase detail to tell create readiness from command latency.
- Flatten lifecycle timing metadata from `create-timing.json` and
  `monitor-timing.json` into each JSONL row before cleanup removes the runtime
  directory.
- Keep benchmark outputs outside this repository unless explicitly committing
  benchmark data.

Done when:

```console
scripts/benchmark-sporevm-lifecycle.sh \
  --image docker.io/library/node:22-alpine \
  --iterations 30 \
  --output-dir /tmp/sporevm-lifecycle
```

produces JSONL and summary statistics for a warm-cache local run, with each
iteration proving two commands executed inside the same VM before cleanup.

Validated locally:

```console
scripts/benchmark-sporevm-lifecycle.sh \
  --image docker.io/library/alpine:3.20 \
  --iterations 1 \
  --output-dir /tmp/sporevm-lifecycle-smoke \
  --rootfs-cache-dir /tmp/sporevm-slice-c-cache \
  --workload-command '/bin/echo script-ok' \
  --no-build

scripts/benchmark-sporevm-lifecycle.sh \
  --image docker.io/library/node:22-alpine \
  --iterations 1 \
  --output-dir /tmp/sporevm-lifecycle-node-alpine-smoke \
  --rootfs-cache-dir /tmp/sporevm-node-alpine-cache \
  --no-build
```

The Node-Alpine run built a cold rootfs, ran a boot-id identity probe and
`node -v` in one VM, returned `v22.22.3`, and wrote one JSONL row with
`create_to_node_ms=26418`, `create_ms=26343`, `identity_exec_ms=32`, and
`workload_exec_ms=43`. A deliberate `exit 7` workload smoke confirms the script
writes JSONL but exits non-zero when any iteration fails.

After adding lifecycle phase timing, a local HVF warm-cache run with the tag
`docker.io/library/node:22-alpine` showed the visible create time was dominated
by rootfs input resolution, not monitor startup or command execution:

```text
create_to_node_ms             median 4141ms
create_ms                     median 3852ms
create_rootfs_resolve_ms      median 3772ms
create_spawn_monitor_ms       median 2ms
create_wait_ready_ms          median 47ms
create_uninstrumented_ms      median 31ms
monitor_asset_resolve_ms      median 27ms
monitor_ready_after_start_ms  median 28ms
identity_exec_ms              median 139ms
workload_exec_ms              median 157ms
```

The same cached rootfs addressed by digest,
`docker.io/library/node@sha256:342bd5d0a0f4b439d6071c45f317dac3bd12459c40aa6b248c9c8ceece181da8`,
removed the repeated tag-resolution cost:

```text
create_to_node_ms             median 362ms
create_ms                     median 76ms
create_rootfs_resolve_ms      median 0ms
create_spawn_monitor_ms       median 1ms
create_wait_ready_ms          median 46ms
create_uninstrumented_ms      median 27ms
monitor_asset_resolve_ms      median 19ms
monitor_ready_after_start_ms  median 20ms
identity_exec_ms              median 136ms
workload_exec_ms              median 151ms
```

These samples were three-iteration local checks, not official benchmark runs,
but they identify the first optimization target: repeated OCI tag resolution on
the `spore create --image <tag>` path.

The lifecycle benchmark now treats that as benchmark setup by default. When the
user passes a mutable tag, the script runs `spore rootfs resolve` once before
the timed loop, records the original tag as `requested_image`, uses the
digest-pinned ref as `image`, and stores `image_resolution_ms` with
`image_resolution_timed=false`. Passing `--measure-tag-resolution` keeps the
old behavior and records `image_resolution_timed=true`, making the slower
tag-in-the-loop measurement explicit.

### Slice D.1: Speed Experiments

Status: active; benchmark-side digest pinning is implemented.

Run the experiments in this order, keeping each one measurable with the
lifecycle benchmark JSONL fields before moving to the next:

1. **Digest-pinned benchmark mode.** Complete for the local script. The
   benchmark resolves mutable tags once before timing by default and records
   both the requested tag and effective digest. A longer 30-iteration
   digest-pinned Node run is still useful for the ComputeSDK-style score
   estimate from `create_to_node_ms`.

2. **Local image ref cache.** Implement the direct-addressed mutable-tag cache
   in `docs/plans/local-image-ref-cache.md`. The benchmark path needs a way to
   avoid repeated registry calls when the caller accepts local reuse, while rootfs
   cache keys remain digest-based. Done when `node:22-alpine` warm-cache runs are
   close to digest-pinned runs without changing rootfs cache key correctness.

3. **Rootfs explicit-path benchmark.** Add a benchmark option or example that
   feeds `spore create --rootfs <cached.ext4>` directly. This isolates VM
   lifecycle startup from all OCI work. Done when `create_rootfs_resolve_ms` is
   not present or negligible and the remaining create time matches monitor
   spawn plus ready wait.

4. **Exec round-trip split.** Add monitor/guest timing for control request
   accepted, vsock stream attached, guest started command, and guest completed
   command. Current exec latency is about 135-155ms, which is small relative to
   tag lookup but large relative to a sub-500ms TTI target. Done when
   `identity_exec_ms` and `workload_exec_ms` can be split into host control,
   vsock setup, guest agent dispatch, and command execution.

5. **CLI startup overhead check.** Track `create_uninstrumented_ms`, which is
   the shell-observed `create_ms` not covered by `createCli` phase timing. The
   median is small locally, but cold process startup can produce outliers. Done
   when longer runs distinguish one-time host process startup from recurring VM
   lifecycle work.

6. **Preboot or snapshot baseline.** Measure a diskless prebooted monitor or
   same-host snapshot path separately from fresh create. Fresh boot is no
   longer the dominant issue once digest refs are used, but preboot/snapshot is
   still the likely path to compete with providers that keep warm sandboxes.
   Done when the benchmark reports both fresh digest-pinned TTI and
   preboot/snapshot TTI without mixing the two modes.

Non-goals for this experiment slice:

- Do not make mutable tag caching invisible or indefinite.
- Do not change rootfs cache keys to ignore the resolved image digest.
- Do not optimize by keeping benchmark-only VMs alive across iterations unless
  the output names that mode separately from fresh create.

### Slice E: Suspend/Resume Integration

Status: complete for diskless local HVF; disk-backed and KVM lifecycle resume
remain follow-ups.

Scope:

- Add `spore suspend NAME --out DIR` through the monitor.
- Add `spore resume DIR --name NAME`.
- Reuse the existing spore manifest and lazy/eager restore machinery.
- Keep disk-backed resume fail-closed until disk identity and disk manifests
  are explicit.

This slice belongs after create/exec/rm is stable because suspend/resume needs
the same monitor lifetime and runtime registry.

Validated locally:

```console
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore create snap-1 --timeout-ms 30000
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore exec snap-1 -- /bin/writeout
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore suspend snap-1 --out /tmp/sporevm-slice-e-spore
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore ls
spore inspect /tmp/sporevm-slice-e-spore
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore resume /tmp/sporevm-slice-e-spore --name snap-2
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore exec snap-2 -- /bin/writeout
SPOREVM_RUNTIME_DIR=/tmp/sporevm-slice-e spore rm snap-2
```

The resulting spore has four devices, a RAM backing file, and a
`sporevm-lifecycle.json` sidecar that preserves lifecycle monitor settings such
as guest port and timeout. A rootfs-backed VM smoke confirms
`spore suspend` rejects disk-backed lifecycle checkpoints before creating an
output directory.

## Verification

- Unit tests:
  - VM name validation.
  - Runtime directory resolution and permissions.
  - Runtime metadata read/write and stale-state handling.
  - Control protocol request/response parsing.
- CLI tests:
  - help text for new commands;
  - unknown VM errors;
  - stale runtime directory errors;
  - `spore run` behavior unchanged.
- Real-host smokes:
  - HVF create/exec/exec/rm with the minimal initrd;
  - HVF create/exec/rm with `--image docker.io/library/alpine:3.20`;
  - HVF diskless suspend/resume/exec/rm;
  - KVM equivalents on an aarch64 KVM host after monitor wake support lands.
- Benchmark smoke:
  - warm-cache `spore create --image node:22-alpine`;
  - two `spore exec` calls against the same VM;
  - local lifecycle timing script with low iteration count.
- Failure smokes:
  - monitor crash before ready;
  - monitor crash after ready;
  - `rm` of a dead monitor;
  - duplicate `create` name;
  - disk-backed `suspend` fails before writing a spore;
  - unsupported backend.

## Resolved Decisions

- Keep `spore run` as the one-shot command.
- Use top-level lifecycle commands instead of a public noun in the common path.
- Use **VM** for the running object, **monitor** for the owning process,
  **spore** for checkpoint artifacts, and **machine state** for low-level
  manifest fields.
- Avoid `sandbox` in the SporeVM core CLI.
- Avoid `machine` as the user-facing runtime noun because it collides with
  manifest machine state.
- Do not add a central daemon for the first persistent lifecycle slice.
- Store live runtime sockets under a runtime directory, not under cache roots.
- Require explicit names for lifecycle VMs. Automatic names can be added later,
  but the first stable surface keeps listing, cleanup, and scripting behavior
  predictable.

## Open Questions

- Should `spore exec` default to argv-only forever, or add a later
  command-string flag?

  Recommendation: keep argv-only in core commands. A later `--shell` flag can
  be added if it proves valuable, but callers can already run `/bin/sh -lc`.

- Should `spore create --image` eventually honor OCI metadata?

  Recommendation: defer. The run-bridge plan already records OCI runtime
  metadata as later image-policy work. Lifecycle should not pull that forward.

## Key Learnings From Pressure-Testing

- A literal daemonless `create` is impossible if the VM remains running. The
  plan narrows "daemonless" to no central daemon and uses one monitor per VM.
- The public noun matters. `sandbox` and `machine` both blur existing ownership
  boundaries, so the plan uses top-level lifecycle commands and keeps nouns
  explicit in docs.
- Lifecycle timing cannot be represented honestly by repeated `spore run`
  calls because the useful signal is multiple commands inside the same fresh
  VM. Persistent `exec` is therefore the useful first product slice, not
  benchmark-only script work.
- Rootfs mutability is the first likely trap. The plan keeps cached rootfs
  images read-only and handles benchmark scratch writes through tmpfs rather
  than cache mutation.
