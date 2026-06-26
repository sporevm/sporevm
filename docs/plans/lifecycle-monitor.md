---
status: active
last_reviewed: 2026-06-26
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - README.md
  - src/local_paths.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/run.zig
  - guest/minimal-initrd/
  - scripts/make-minimal-exec-initrd.sh
  - scripts/benchmark-sporevm-lifecycle.sh
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/local-image-ref-cache.md
---

# Named VM Lifecycle Plan

## Summary

Local named-VM lifecycle is stable for HVF and KVM
create/exec/suspend/resume/ls/rm. SporeVM can create a named VM, keep it alive
in one per-VM monitor process, execute multiple commands over the guest agent,
checkpoint it into a spore, resume it under a new name, and list/remove it
through a private runtime registry.

The active work is no longer the stable lifecycle CLI shape. It is speed:
tag-resolution caching, rootfs-path benchmark isolation, exec timing
breakdowns, and preboot or same-host snapshot baselines.

## Landed Product Contract

```console
spore create bench-1 --image docker.io/library/alpine:3.20
spore exec bench-1 -- /bin/echo hi
spore exec bench-1 -- /bin/sh -lc 'cat /proc/sys/kernel/random/boot_id'
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
spore rm bench-2
```

`spore run` remains the one-shot convenience command. Named live-VM lifecycle is
stable for `create`, `exec`, `suspend`, `resume --name`, `ls`, and `rm`.
`spore --json create`, `spore --json suspend`, `spore --json resume`,
`spore --json ls`, and `spore --json rm` provide the machine-readable lifecycle
state surface; `spore exec` keeps guest stdout and stderr as workload streams.
Monitor processes deny child process execution through an embedded macOS
sandbox profile or Linux seccomp filter.

Checkpointing extends the same named-VM model:

```console
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
```

The common path deliberately has no public noun. Docs use:

- **VM** for a currently running guest owned by a local monitor process;
- **monitor** for the long-lived host process that owns one VM;
- **spore** for a sealed checkpoint artifact;
- **machine state** for architectural state stored inside a spore.

Avoid `sandbox` in the SporeVM core CLI. Consumers such as cleanroom own sandbox
policy, secrets, egress, mounts, workspace semantics, and scheduling.

## Current State

- `spore create`, `spore exec`, `spore suspend`, named `spore resume`,
  `spore rm`, `spore ls`, and `spore monitor` are available on supported
  backends; the stable surface is
  `create`/`exec`/`suspend`/`resume --name`/`ls`/`rm`.
- Monitor processes deny child process execution through an embedded macOS
  sandbox profile or Linux seccomp filter. `mise run smoke:monitor-jail` covers
  the denied-operation path.
- They use a private runtime registry under `SPOREVM_RUNTIME_DIR`,
  `$XDG_RUNTIME_DIR/sporevm`, or a private temp fallback.
- VM names are explicit and restricted to a conservative path-safe set.
- One per-VM monitor owns the hypervisor VM, vCPU loop, virtio state, rootfs fd,
  console log, vsock state, and newline-delimited JSON control socket.
- HVF and KVM monitor mode support minimal-initrd, `--rootfs`, and `--image`
  lifecycle VMs locally on their supported host platforms.
- The guest agent uses per-command session ids, so repeated attaches do not
  duplicate execution but fresh `spore exec` calls can run sequentially in one
  boot.
- `spore suspend NAME --out DIR` and `spore resume DIR --name NAME` work for
  diskless lifecycle VMs and image-created writable rootfs lifecycle VMs on HVF
  and KVM.
- KVM monitor wake support has landed for create, exec, repeated exec, ls, and
  rm using `immediate_exit` plus a signal wake for host-attached control streams.
- Disk-backed lifecycle suspend/resume uses monitor-owned rootfs and disk
  identity. Image-created VMs use chunked rootfs storage; explicit
  `spore create --rootfs PATH` VMs use exact immutable rootfs artifacts.
- `spore create --net [--allow-cidr CIDR] [--allow-host HOST]` reuses the
  existing virtio-net -> `spore-netd` path. The monitor owns the helper
  lifetime, records requested policy in checkpoints, and named resume starts a
  fresh helper under that policy. Live TCP flows and learned DNS answers are not
  checkpointed.

## Runtime Directory

Live VM state is runtime state, not cache state:

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

Runtime directories must be private to the current user. Stale directories fail
closed unless the recorded monitor pid is dead and the user removes or recreates
the VM.

## Control Protocol

The monitor listens on a local Unix socket for newline-delimited JSON:

```json
{"type":"exec","argv":["/bin/echo","hi"],"timeout_ms":30000}
{"type":"suspend","out_dir":"/tmp/bench.spore"}
{"type":"shutdown"}
```

The protocol is local-only in the first lifecycle version. There is no TCP
control socket and no auth story beyond filesystem permissions. A separate
status request can be added later, but unknown request types fail closed today.

## Active Work

### Speed Experiments

`scripts/benchmark-sporevm-lifecycle.sh` now resolves mutable image tags once
before timed iterations by default and records both the requested tag and
effective digest. The next speed work should stay measurement-led:

1. Add the conservative tag-to-digest resolution cache from
   `docs/plans/local-image-ref-cache.md` so warm-cache `node:22-alpine` runs
   approach digest-pinned runs without changing rootfs cache correctness.
2. Add or document a rootfs explicit-path benchmark mode using
   `spore create --rootfs <cached.ext4>` so VM lifecycle startup is isolated from
   OCI work.
3. Split exec timing into host control request, vsock stream attach, guest agent
   dispatch, and command execution.
4. Track CLI startup overhead separately from recurring monitor/VM work.
5. Measure preboot or same-host snapshot baselines separately from fresh create.

### KVM Monitor Wake

Status: landed for create, exec, repeated exec, ls, and rm.

KVM lifecycle parity now uses a backend wake path for host-attached control
streams while `KVM_RUN` is active. Monitor requests set `immediate_exit`, send a
signal to the vCPU thread, poll the shared lifecycle control hook, and flush
pending virtio-vsock RX before re-entering the guest.

### Checkpoint Lifecycle

Disk-backed lifecycle checkpoints carry explicit disk/rootfs ownership through
the monitor. `spore create --image` records chunked immutable-rootfs identity in
`spec.json`; `spore create --rootfs PATH` records exact immutable-rootfs
identity in the digest cache. The monitor preserves that identity while opening
the live writable root disk, and `spore suspend` writes lifecycle metadata into
the checkpoint so named `spore resume` can restore the same disk model.

## Non-Goals

- No central `spore daemon` for the first lifecycle surface.
- No `spore sandbox` core command.
- No OCI Entrypoint, Cmd, User, Env, or Workdir semantics.
- No implicit shell wrapping in `spore exec`; callers can run `/bin/sh -lc`.
- No stdin streaming, TTY, or interactive terminal in the first monitor version.
- No multi-vCPU lifecycle support until the underlying run path supports it.
- No writable cached OCI rootfs.
- No inbound ports, broad UDP forwarding, L7 policy, or live network-flow
  checkpointing for named lifecycle networking.

## Verification

- Unit tests: VM name validation, runtime directory resolution and permissions,
  metadata read/write, stale-state handling, control protocol parsing.
- CLI checks: help text, unknown VM errors, stale runtime errors, duplicate
  create name, unchanged `spore run` behavior.
- Real-host smokes: local HVF create/exec/exec/rm, KVM create/exec/exec/ls/rm,
  HVF and KVM `--image` suspend/resume/exec/rm with writable-rootfs state
  preserved.
- Benchmark smoke: low-iteration lifecycle timing run.
- Failure smokes: monitor crash before/after ready, `rm` of a dead monitor,
  missing exact rootfs artifact rejection, unsupported backend.

## Resolved Decisions

- Keep `spore run` as the one-shot command.
- Use top-level lifecycle commands instead of a public noun in the common path.
- Use one monitor process per VM, not a central daemon.
- Store live sockets under a runtime directory, not under cache roots.
- Require explicit VM names for the first stable surface.
- Keep argv-only execution in core commands; a later `--shell` flag can be added
  if it proves useful.
- Defer OCI runtime metadata. Lifecycle should not pull image-policy work ahead
  of the run/rootfs contract.
