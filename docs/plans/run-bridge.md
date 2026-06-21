---
status: landed
last_reviewed: 2026-06-21
spec_refs:
  - docs/plans/foundation.md
  - docs/rootfs.md
  - README.md
  - src/local_paths.zig
  - src/run.zig
  - src/resume.zig
  - src/fanout.zig
  - src/rootfs.zig
  - guest/minimal-initrd/
  - scripts/make-minimal-exec-initrd.sh
  - scripts/smoke-counter-fanout.sh
related_plans:
  - docs/plans/foundation.md
  - docs/plans/immutable-rootfs-resume.md
  - docs/plans/lifecycle-monitor.md
---

# Spore Run Bridge Plan

## Summary

The `spore run` bridge has landed. It turns the low-level VMM foundation into a
product-shaped command runner without becoming a container runtime: boot a
supported aarch64 Linux guest, send one explicit argv request over vsock, stream
stdout/stderr, return the guest command status, and fail closed when boot assets
or workload inputs are unsupported.

The landed bridge covers default run assets, read-only rootfs execution, cached
OCI rootfs convenience, running from an existing spore, streaming output, exit
and host-signalled capture, product `spore resume`, explicit fork/fan-out, and
immutable-rootfs resume for captured `--image` workloads.
The default managed run kernel is also checked against its release `.config` for
guest runtime features that Docker/containerd expect, including file locking,
tmpfs/shmem, fsnotify/inotify, cgroups, and cgroup BPF support.

## Landed Product Contract

Run one explicit argv request:

```console
spore run -- /bin/writeout
spore run --kernel Image --initrd minimal.cpio -- /bin/writeout
```

When kernel or initrd are omitted, `spore run` resolves:

- kernel: the managed SporeVM run aarch64 kernel, honoring
  `SPOREVM_KERNEL_IMAGE` as an explicit local override, with managed downloads
  requiring the release `.config` to include the run-kernel Docker-adjacent
  options;
- initrd: the installed minimal exec initrd, honoring `SPOREVM_RUN_INITRD`.

Fresh `spore run` streams typed stdout/stderr frames over one host-initiated
vsock connection and exits with the guest command status. The old product
`--json` final-frame mode is gone before 1.0; any future machine-readable stream
should be a deliberate JSONL/event mode.

Run one explicit argv request from a completed base spore:

```console
spore run --from base.spore -- /bin/writeout
```

`--from` resumes the spore, automatically uses proof-backed local RAM when the
same-host `ram.backing.proof` validates, reopens any verified immutable rootfs
artifact recorded in the manifest, sends the argv after `--` to the restored
exec agent, streams stdout/stderr, and exits with the command status. It is
mutually exclusive with fresh boot inputs such as `--kernel`, `--initrd`,
`--rootfs`, and `--image`; RAM size is manifest-derived. The restored guest must
be able to accept a fresh exec session. Signal-captured running workloads remain
a `spore resume`, `spore fork`, or `spore fanout` path until the guest-agent
protocol can reconnect to or multiplex active commands.

Run from an explicit read-only ext4 rootfs:

```console
spore run --rootfs rootfs.ext4 -- /bin/echo hi
```

Build or reuse a cached OCI-derived ext4 rootfs, then delegate to the same
read-only rootfs path:

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

`--image` remains explicit. `spore run docker.io/library/alpine:3.20 ...` is not
an image shorthand, and SporeVM does not apply OCI Entrypoint, Cmd, User, Env, or
Workdir semantics in this bridge.

Capture a running workload on exit or on a host signal:

```console
spore run --capture counter.spore --capture-on INT -- /bin/counter
# press Ctrl-C to capture
spore fork counter.spore --count 10 --out counter.children/
spore fanout counter.children --parallel --for 20s
```

Plain `--capture DIR` captures after the guest command exits and preserves the
guest command status. `--capture-on INT|TERM|HUP|USR1|USR2` captures on the
first matching host signal and exits zero unless `--continue-after-capture` is
set; a second matching signal exits 130.

`spore resume SPORE` resumes exactly one spore. Fan-out is intentionally explicit:
mint child spores with `spore fork`, then resume them individually or through
`spore fanout`.

## Current State

- `src/run.zig` implements one-shot run argument parsing, default asset
  resolution, read-only rootfs attachment, direct image cache lookup/build,
  running from existing spores, streaming output, and exit or host-signalled
  capture.
- `src/resume.zig` implements product `spore resume` for one diskless or verified
  immutable-rootfs spore at a time.
- `src/fanout.zig` implements product fan-out over an existing child-spore
  directory.
- Managed kernel resolution lives in the product path and verifies downloaded
  assets, including the run-kernel `.config` sidecar.
- The minimal initrd mounts cgroup2 at `/sys/fs/cgroup` and exposes it inside
  rootfs-backed runs so Docker sees a unified writable cgroup hierarchy.
- `scripts/make-minimal-exec-initrd.sh` builds the minimal guest exec agent and
  diskless helper binaries used by the bridge smokes.
- `scripts/smoke-run.sh`, `scripts/smoke-run-capture.sh`,
  `scripts/smoke-run-file-locking.sh`, `scripts/smoke-run-cgroup.sh`,
  `scripts/smoke-counter-fanout.sh`, and `scripts/smoke-rootfs-fanout.sh` cover
  the landed bridge surface.

## Safety And Invariants

- Default command output writes guest stdout to host stdout and guest stderr to
  host stderr as frames arrive, then exits with the guest command's status.
- Frame payloads are bounded and typed. Malformed frames fail the run.
- Missing default assets fail before booting a VM.
- Downloaded kernels are verified before use, and the managed run kernel must
  provide the file-locking and Docker-adjacent options required by the product
  smoke surface.
- The guest cgroup2 mount is runtime-owned. Workloads may use it, but SporeVM
  does not expose a host cgroup policy boundary through this mount.
- Cached OCI rootfs images are never mounted writable by default.
- Rootfs execution uses the existing virtio-blk device and does not widen the
  frozen device model.
- `spore run --from` does not accept fresh boot inputs; kernel, initrd, RAM size,
  optional local RAM backing, and optional immutable rootfs identity come from
  the spore.
- `spore run --from` starts a new exec-agent session. It does not reconnect to
  or interrupt a command that was already running when the source spore was
  captured.
- `--rootfs PATH --capture` is rejected until an import/preload command
  can record portable rootfs identity for arbitrary local images.
- Resumed captured workloads are visible through restored guest console output.
  Separated stdout/stderr after resume requires a later reconnect or persisted
  host-stream state contract.
- `spore resume` does not grow a `--count` flag. Repeated child execution remains
  `spore fork` plus repeated `spore resume`, or `spore fanout`.

## What Stayed Out

- OCI Entrypoint, Cmd, User, Env, Workdir, workspace, secret, and network policy.
- Writable cached rootfs or persisted disk mutation.
- Bundle-aware initial workload input. Bundles distribute spores, not first-run
  images.
- A first-class `spore capture` verb. Capture remains an option on `spore run`.
- Event-stream JSON output for fresh runs.
- Separated stdout/stderr after product resume.
- General disk manifests. Immutable rootfs identity is handled in
  `docs/plans/immutable-rootfs-resume.md`; arbitrary writable disk capture is a
  later foundation problem.

## Verification

- `mise run check`
- `mise run smoke`
- `mise run smoke:counter-fanout`
- `mise run smoke:rootfs-fanout`
- `mise run smoke:live-rootfs-fanout`
- `scripts/smoke-run-oci-rootfs.sh -- /bin/echo hi`

## Resolved Decisions

- The first product bridge is one-shot boot/exec/status, not a lifecycle monitor.
- Direct OCI input uses `--image REF`, never a positional image argument.
- Rootfs execution starts read-only and explicit.
- Product resume handles one spore. Fan-out stays visible as fork plus resume or
  the `spore fanout` helper.
- Resume visibility starts with guest console streaming.
- Immutable rootfs resume is digest-authoritative; OCI provenance is not restore
  authority.

## Remaining Work

The run bridge itself is landed. Future work belongs in narrower plans:

- immutable rootfs preload/bundle distribution:
  `docs/plans/distribution.md`;
- named VM lifecycle and benchmark speed work:
  `docs/plans/lifecycle-monitor.md`;
- RAM economics, dirty tracking, and fleet fan-out distribution:
  `docs/plans/foundation.md`.
