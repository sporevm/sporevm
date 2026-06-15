---
status: active
last_reviewed: 2026-06-15
spec_refs:
  - docs/plans/foundation.md
  - docs/rootfs.md
  - README.md
  - src/run.zig
  - src/rootfs.zig
  - scripts/make-minimal-exec-initrd.sh
  - scripts/ensure-managed-kernel.sh
related_plans:
  - docs/plans/foundation.md
---

# Spore Run Bridge Plan

## Summary

`spore run` is the product bridge between the low-level VMM foundation and a
user-visible "run a command" experience. It should stay narrower than a full
container runtime: boot a supported aarch64 Linux guest, send one explicit argv
request over vsock, stream stdout/stderr, return the command status, and
fail closed when required boot assets or workload inputs are unsupported.

The current implementation proves the host/guest control path with default run
assets, read-only rootfs execution, and direct OCI image cache convenience. The
next bridge is lifecycle: turn the harness-only capture/resume path into a
product surface that can run a long-lived process, capture it on a host signal,
fork it, and resume each child through `spore resume`.

The first OCI-capable milestone is intentionally two-step:

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

Direct image references stay explicit through a flag:

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

This keeps `spore run -- /bin/writeout` unambiguous, avoids smuggling OCI
runtime semantics into the first rootfs slice, and preserves the foundation
plan boundary that consumers own image policy.

## Problem

The current `spore run` and `spore resume` commands are good enough for short
fresh runs and explicit single-spore resumes, but the lifecycle still stops
short of host-triggered capture:

- `spore run` has no host-triggered capture path. Backend run loops can
  snapshot after a fixed delay, but not when the operator sends Ctrl-C or
  another host signal.
- fresh `spore run` streams stdout/stderr, but the capture path still needs to
  request a snapshot from a safe backend loop point without corrupting in-flight
  vsock/device state;
- the run-vsock stream is part of captured virtio state, and the KVM snapshot
  path already rejects snapshots while vsock has pending packets, so capture
  must be driven from a safe run-loop point rather than directly from a signal
  handler.

Without this next bridge, the fork/fan-out thesis remains demonstrable through
harnesses but awkward from the product CLI.

## Goals

- Make the minimal run path ergonomic enough to test directly:

  ```console
  spore run -- /bin/writeout
  ```

- Keep explicit override paths for kernel and initrd so smoke tests,
  experiments, and cleanroom can control boot assets.
- Add rootfs disk execution without changing the frozen device model.
- Make the first rootfs execution mode read-only and explicit.
- Connect OCI to `run` first through the existing deterministic ext4 builder.
- Keep direct OCI image support as cache/build orchestration, not a full OCI
  runtime contract.
- Keep asset setup messages off guest stdout so normal command output remains
  usable in shell pipelines.

## Non-Goals

- No OCI Entrypoint/Cmd/User/Env/Workdir behavior in the first rootfs slices.
- No implicit shell wrapping. `spore run --rootfs alpine.ext4 -- echo hi` means
  exec `echo`; it does not search shells or rewrite argv.
- No writable cached OCI rootfs in the first rootfs slices.
- No network, secret, workspace, mount, or package-manager policy.
- No bundle-aware `spore run` in this track. Spore bundles are for packed
  spores and fan-out distribution, not initial workload image input.
- No disk capture in the spore manifest as part of the run bridge. v0 disk
  restore continues to require the same backing disk out of band until the
  foundation plan adds disk manifests.

## Current State

- `src/run.zig` accepts optional `--kernel`, optional `--initrd`, and one argv
  request. When omitted, the CLI resolves default run assets before boot.
- Backend selection already defaults to `auto`, resolving to HVF on Darwin
  arm64 and KVM on Linux/aarch64.
- `scripts/ensure-managed-kernel.sh run` resolves, downloads, verifies, and
  caches the managed cleanroom-kernels SporeVM run kernel. The run kernel
  combines initrd boot with virtio-blk and ext4 support.
- `scripts/make-minimal-exec-initrd.sh` builds a tiny initrd with the guest
  exec agent and fixed helper binaries.
- `zig build` installs that minimal exec initrd at
  `share/sporevm/minimal-exec-initrd.cpio`.
- Fresh `spore run` streams stdout/stderr over a small typed vsock frame
  protocol and exits with the guest command status. The product CLI rejects the
  old `--json` final-frame mode.
- `spore run --rootfs rootfs.ext4 -- <argv...>` attaches an ext4 rootfs
  read-only through the existing virtio-blk device and chroots before exec.
- `spore rootfs build` already materializes OCI images into deterministic ext4
  images and records metadata.
- `scripts/smoke-run-oci-rootfs.sh` validates the two-step OCI path by
  building `docker.io/library/alpine:3.20`, checking digest-pinned
  `resolved_image_ref` metadata, and running an explicit argv from the rootfs.
- `spore run --image REF -- <argv...>` resolves REF to a digest-pinned
  linux/arm64 image identity, builds or reuses a cached ext4 rootfs, and then
  delegates to the same read-only `--rootfs` execution path.
- Harness capture remains real on both backends through `snapshot_after_ms`,
  including eager, lazy, and trusted local RAM backing modes. Host-signalled
  capture from `spore run` is still pending.
- Product `spore resume SPORE` now promotes the backend resume path for one
  spore at a time and defaults RAM size from `manifest.platform.ram_size`.
- The minimal exec agent has an offset-aware attach/replay request shape for a
  future resume-aware run stream, but product resume does not depend on it yet.
- Product `spore resume` can stream the guest console through the existing
  backend console sink, but it cannot assume the host-side run-vsock stream
  from a captured `spore run` still exists after restore.

## Target Model

### Minimal Initrd Run

```console
spore run -- /bin/writeout
spore run --kernel Image --initrd minimal.cpio -- /bin/writeout
```

When kernel or initrd are omitted, `run` resolves default run assets:

- kernel: managed SporeVM run aarch64 kernel, honoring
  `SPOREVM_KERNEL_IMAGE` as the explicit local override;
- initrd: the installed minimal exec initrd, with `SPOREVM_RUN_INITRD` as the
  explicit local override.

The default initrd is a developer/product bridge, not the future rootfs.
Commands only work if they are present inside the initrd.

Fresh `spore run` uses one host-initiated vsock connection for the request and
for the command result stream. The streaming protocol should be deliberately
small: typed, length-prefixed frames for stdout, stderr, and exit status are
enough. The host writes stdout frames to stdout and stderr frames to stderr as
they arrive, then exits with the exit frame's code. The old single JSON exit
frame is not a compatibility boundary before 1.0.

### Rootfs Run

```console
spore run --rootfs rootfs.ext4 -- /bin/echo hi
spore run --kernel Image --initrd minimal.cpio --rootfs rootfs.ext4 -- /bin/echo hi
```

The host attaches the rootfs ext4 image as virtio-blk. The initrd agent mounts
it read-only, sets up the minimum guest runtime required to exec an explicit
argv from that filesystem, and uses the same stdout/stderr/status stream.

The first rootfs version runs as root with a closed env, unless the current
`run` contract has already gained explicit env support by then. OCI user,
working directory, entrypoint, cmd, and env are later image-policy work.

### OCI Rootfs Build And Run

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

This is the first point where SporeVM can take an OCI image and run something
from it. The image is not consumed directly by the VMM. It is first
materialized into an ext4 rootfs by the existing builder, then attached as a
block device.

### Direct Image Convenience

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

Direct image mode resolves or builds a cached rootfs image, then delegates to
the same `--rootfs` path. The cache key must include at least the resolved
image digest, platform, rootfs builder version or format version, and any
material build options. Mutable tags are resolved before cache lookup records
the reusable identity.

Direct image mode remains explicit through `--image`; the first positional
argument is not overloaded as an image reference.

The cache root is `SPOREVM_ROOTFS_CACHE_DIR` when set, otherwise the platform
cache directory under `sporevm/rootfs`. Setup and cache messages go to stderr.

### Host-Signalled Capture And Resume

```console
spore run --image ruby-demo --capture-on-abort ruby-counter.spore -- ruby /demo/counter.rb
# press Ctrl-C to capture
spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
for child in ruby-counter.children/*; do spore resume "$child" & done
```

The product lifecycle should stay explicit:

- `spore run` starts a new workload. Capture is an option on that run through a
  path-valued `--capture-on-abort SPORE` flag.
- `spore fork` mints one or more child spores from an existing spore.
- `spore resume` starts exactly one spore.

`spore resume` deliberately has no `--count` flag. Repeatedly resuming the
exact same spore would duplicate VM identity, while making `resume` secretly
fork would hide the lifecycle. Fan-out stays explicit and simple: run
`spore fork SPORE --count N --out DIR`, then loop or orchestrate
`spore resume DIR/<child>` for each child. Distributed fan-out assigns hosts
subsets of the child spore directories minted by `spore fork`.

There is no first-class `spore capture` verb in the planned product surface.
That would split the mental model without adding capability: a new VM is still
being run until it is captured.

The first capture trigger is host-side and generic. In interactive mode,
`spore run --capture-on-abort ...` treats the first Ctrl-C as "capture now"
rather than "abort now"; a second interrupt can still abort. The host consumes
that first abort signal and must not forward it into the guest before capture,
otherwise the captured process may have already handled SIGINT or begun
shutting down. Non-interactive callers can use `--capture-signal NAME` to
request a specific host signal such as `USR1`. The signal handler only sets an
atomic capture request or wakes the VMM loop. The actual snapshot is written
from the normal VMM loop after pending device work has been made safe. The
default `--capture-on-abort` behavior is to write the spore and exit. Future
policy can add `--after-capture exit|continue|pause`, but the Ruby counter demo
and CI fan-out proof only need capture-then-exit.

Streaming output is part of this same surface. Fresh `spore run` now streams
stdout/stderr as the workload runs. `spore run --capture-on-abort ...` should
preserve that visibility until the host capture signal arrives, then write the
spore from a safe backend loop point.

Fresh `spore run` can stream over the run-vsock connection. Resuming a captured
run is different: the guest may still believe it has an accepted vsock
connection, but the host-side `HostStream` object is not a portable spore
artifact. The first product resume surface should therefore stream restore-time
guest console output, which already exists on both backends. If we need
stdout/stderr separation after resume, add an explicit guest-agent reconnect or
host-stream state model later; do not hide that behind `spore resume`.

This avoids requiring a guest API before the thesis is proven. A later
guest-visible readiness/checkpoint API can still be added for applications that
want to choose their own capture point, but it is not required for the first
compelling demo.

## Safety And Invariants

- Default command output writes guest stdout to host stdout and guest stderr to
  host stderr as it arrives, then exits with the guest command's exit code.
- The run-vsock output protocol is a framed stream, not an unbounded append
  buffer. Frames are length-limited and typed as stdout, stderr, exit, or
  protocol error.
- Product `--json` single-final-frame behavior has been removed. Any future
  machine-readable output should be an explicit JSONL/event mode; the first
  streaming slice optimizes for normal CLI stdout/stderr plus process exit
  status.
- Missing default assets fail before booting a VM.
- Default asset cache writes use temporary files plus atomic rename.
- Downloaded kernels are verified before use.
- Cached OCI rootfs images are never mounted writable by default.
- Unsupported backends fail closed before asset setup when possible.
- Rootfs execution does not widen the device model. It uses the existing
  virtio-blk device.
- Rootfs inputs are workload inputs, not spore manifest state, until disk
  manifests land in the foundation plan.
- The initrd agent treats host requests and rootfs contents as untrusted input.
  New parsers or binary protocols require tests, and attacker-influenced
  parsers follow the repository security guidance.

## Interaction With The Foundation Plan

This plan does not replace the foundation slices. It is a bridge track layered
over already-landed foundation capabilities:

- Slice 1/2 provide boot, initrd, virtio-blk, and vsock on KVM/HVF.
- The current `spore run` bridge proves one-shot boot/exec/status over vsock.
- Rootfs execution uses existing virtio-blk support; it does not add a device.
- The OCI rootfs builder is an offline utility by design and remains outside
  the VMM monitor.
- Slice 5/6 RAM economics and spore distribution remain the release-critical
  foundation path. Direct OCI image input is not the same thing as publishing
  or distributing spores.

The bridge starts mattering to the foundation plan again when disk-backed
workloads must suspend, fork, and resume portably. That is where disk manifests,
rootfs identity, and cache policy need a foundation-level decision.

## Delivery Strategy

### Slice A: Default Run Assets

Status: implemented.

Scope:

- Make `--kernel` and `--initrd` optional for `spore run`.
- Add a default run-asset resolver used only by the CLI path, not the spore
  manifest format.
- Install or otherwise make the minimal exec initrd discoverable from a normal
  `zig build` output.
- Keep explicit `--kernel` and `--initrd` overrides.
- Keep `SPOREVM_KERNEL_IMAGE`; add `SPOREVM_RUN_INITRD`.

Done when:

```console
mise run build
zig-out/bin/spore run -- /bin/writeout
zig-out/bin/spore run --kernel Image --initrd minimal.cpio -- /bin/writeout
```

work on a supported local backend, with setup noise on stderr and command
output/result semantics unchanged.

### Slice B: Read-Only Rootfs Attach And Exec

Status: implemented. Default no-env resolution uses the managed SporeVM run
kernel published by `cleanroom-kernels`.

Scope:

- Add `--rootfs PATH` to `spore run`.
- Open the rootfs image read-only on the host and attach it as virtio-blk.
- Extend the minimal initrd agent to mount the block device read-only.
- Exec explicit argv inside the mounted rootfs via `chroot` or an equivalent
  simple root switch.
- Keep closed env and root user unless explicit env/user support has landed.

Done when:

```console
spore run --rootfs rootfs.ext4 -- /bin/echo hi
spore run --rootfs rootfs.ext4 -- /bin/false
```

prove stdout/stderr/status propagation from binaries that live in the rootfs.

### Slice C: OCI Two-Step Smoke

Status: implemented.

Scope:

- Document and validate the two-step OCI path using the existing rootfs
  builder.
- Add a smoke script or test fixture that builds a small linux/arm64 rootfs
  and runs an explicit argv from it on supported hardware.
- Require digest metadata in the smoke output so tag-based runs can be traced
  back to a resolved image identity.

Done when:

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

is the documented first OCI-capable workflow.

### Slice D: Direct Image Cache

Status: implemented.

Scope:

- Add `--image REF` as sugar over `rootfs build` plus `--rootfs`.
- Resolve tags before choosing a cache entry.
- Cache rootfs ext4 outputs by resolved image digest, platform, and builder
  identity.
- Keep the default rootfs mounted read-only.
- Keep `--rootfs` as the lower-level escape hatch.

Done when:

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

builds or reuses a cached rootfs and then exercises the same rootfs execution
path as Slice B.

### Slice E: Runtime Metadata And Writable State

Scope:

- Add only the OCI runtime metadata that SporeVM intentionally owns, if any.
- Consider explicit `--env`, `--workdir`, and `--user` flags before honoring
  image defaults implicitly.
- Add an ephemeral writable layer or scratch disk before supporting workloads
  that need mutable root state.

This is deliberately later because it crosses from VMM bridge into workload
policy.

### Slice F: Host-Signalled Run Capture And Resume Surface

Status: in progress. F1 and F2 have landed; F3 is the next implementation
slice. The full Ruby counter demo remains the Slice F completion proof.

Scope:

- Add `spore run --capture-on-abort PATH` for long-running workloads.
- In interactive capture mode, make the first Ctrl-C request capture and a
  second interrupt abort. The first abort signal is consumed by the host and is
  not forwarded to the guest before capture.
- Add `--capture-signal NAME` for non-interactive host-side capture triggers.
- Snapshot from the backend run loop, not directly from the signal handler.
- Stream guest output while the workload is running so demos can show progress
  before capture, and stream resumed child output through the same path.
- Add `spore resume SPORE` as the product resume verb for exactly one captured
  or forked spore.
- Keep fan-out as `spore fork --count N --out DIR` plus repeated
  `spore resume DIR/<child>` calls; `spore resume` must not grow a `--count`
  flag in this slice.

#### Slice F1: Product `spore resume`

Status: implemented.

Scope:

- Add `spore resume SPORE` to the main CLI as a single-spore resume command.
- Reuse the existing backend resume machinery instead of adding a new spore
  format or lifecycle path.
- Default memory size from `manifest.platform.ram_size`. Keep an override only
  for explicit compatibility experiments.
- Do not require a kernel or initrd for resume unless a backend call path still
  needs a temporary implementation detail; the spore contains machine state,
  not a fresh boot request.
- Default to verified chunk restore. A trusted same-host RAM backing opt-in can
  follow as a separate flag once the product wording is clear.
- Keep resumed console output streaming as the harness does today; this is
  enough for fork-aware initrd children and gives the next slices a product
  command to call. Do not claim separated stdout/stderr from a resumed captured
  `spore run` until there is an explicit reconnect or host-stream state model.

Done when:

```console
spore resume ruby-counter.spore
spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
for child in ruby-counter.children/*; do spore resume "$child" & done
```

resumes one spore per command on the supported local backend, fails closed on
platform mismatch, refuses `--count`, and shows resumed guest console output as
the VM runs.

#### Slice F2: Simple Streaming Run Protocol

Status: implemented.

Scope:

- Replace the current final JSON exit frame with a small typed frame protocol on
  the existing host-initiated run-vsock connection.
- Stream stdout and stderr chunks as they are read from the child process
  instead of buffering the whole result in the guest agent.
- Send a final exit frame with the child exit code. The host process exits with
  that code after draining prior output frames.
- Remove, reject, or defer `--json` for this path. If machine-readable events
  are needed later, add an explicit JSONL/event mode rather than preserving the
  current final-frame shape.
- Keep frame sizes bounded and add parser tests because frame headers and
  lengths are attacker-influenced guest data.

Done when a command that writes periodically shows output before it exits,
large output does not require guest-side buffering, and the host process exit
status still matches the guest command.

#### Slice F3: Host-Requested Snapshot Trigger

Status: next.

Scope:

- Add an explicit backend run-loop capture request, separate from
  `snapshot_after_ms`, so host code can ask the normal run loop to snapshot at a
  safe point.
- Add `spore run --capture-on-abort PATH` and `--capture-signal NAME` parsing.
- In interactive mode, install a host-side handler where the first Ctrl-C sets
  the capture request and the second interrupt aborts.
- For KVM, handle signal-interrupted `KVM_RUN` as a loop wakeup when a capture
  request is pending; the generic ioctl helper currently treats `EINTR` as an
  error.
- Snapshot only after pending MMIO/device completion has been settled. Preserve
  the existing fail-closed behavior when vsock has unsnapshot-safe pending
  packets.

Done when a non-interactive smoke can send the configured host signal to
`spore run --capture-on-abort out.spore -- /bin/long-running-command`, observe
`out.spore/manifest.json`, and resume that spore through Slice F1.

#### Slice F4: Resume-Aware Output

Scope:

- Make the long-running run demo visible after resume without depending on an
  uncaptured host-side vsock stream.
- Start with restore-time guest console streaming, because that path already
  round-trips through backend resume.
- Decide explicitly whether the guest run agent should also mirror workload
  output to the guest console before capture, or whether a reconnectable agent
  endpoint is required for separated stdout/stderr after resume.
- The current minimal exec agent already accepts offset-based attach requests
  and keeps bounded replay buffers, but `spore run --capture-on-abort` does not
  yet persist stream offsets for product resume to use.
- Keep the first product guarantee modest: resumed children are visible as they
  run. Separated stdout/stderr after resume is a later contract unless this
  slice chooses a reconnect protocol.

Done when resumed children from a captured run produce visible output
immediately through `spore resume`.

#### Slice F5: Ruby Counter Fan-Out Demo

Scope:

- Build or document a small linux/arm64 rootfs containing the Ruby counter
  workload.
- Validate capture-on-abort, `spore fork --count 10`, and parallel product
  `spore resume` children from the captured process state.
- Keep this as a smoke/demo boundary; do not add OCI runtime defaults, writable
  rootfs state, or `resume --count`.

Done when:

```console
spore run --image ruby-demo --capture-on-abort ruby-counter.spore -- ruby /demo/counter.rb
# press Ctrl-C to capture
spore fork ruby-counter.spore --count 10 --out ruby-counter.children/
for child in ruby-counter.children/*; do spore resume "$child" & done
```

shows a live Ruby process counting before capture and ten resumed children
streaming interleaved counters from the same captured process state.

## Verification

- Unit tests for run argument parsing and default asset resolution.
- Unit tests for cache key construction, cache metadata matching, and absolute
  cache directory creation.
- Shell syntax and build checks for any generated initrd helpers.
- HVF smoke for default initrd run on Apple Silicon.
- KVM smoke for default initrd run on Linux/aarch64.
- HVF and KVM smokes for `--rootfs`.
- OCI two-step smoke using a small linux/arm64 image.
- Direct image smoke showing first-run build, second-run cache reuse, and
  clean command stdout/stderr streaming.
- Unit tests for `spore resume` argument parsing, especially rejecting
  `--count`.
- Unit tests for manifest-derived resume memory defaults.
- Backend unit or harness tests for host-requested snapshot triggers that do
  not execute inside the signal handler.
- KVM signal-capture smoke that proves `KVM_RUN` interruption wakes the run loop
  instead of surfacing as a generic ioctl failure.
- Streaming protocol tests for stdout/stderr frame ordering, frame length
  validation, and final exit-code propagation.
- Negative tests:
  - missing default assets;
  - unsupported host/backend;
  - corrupt or architecture-mismatched rootfs metadata when metadata is
    available;
  - rootfs command not found;
  - malformed guest output frames;
  - asset setup messages do not pollute guest stdout.

## Resolved Decisions

- Earlier bridge work deliberately started with default run assets, not rootfs.
- The first OCI-capable milestone is two-step `rootfs build` plus
  `run --rootfs`.
- Direct OCI input uses `--image REF`, not a positional image argument.
- Rootfs execution starts read-only to avoid mutating cached image state.
- OCI Entrypoint/Cmd/User/Env/Workdir are deferred.
- Bundle-aware run semantics are outside this bridge track.
- Direct image cache entries are keyed by resolved digest-pinned image ref,
  linux/arm64 platform, and rootfs builder version. The first build uses the
  resolved digest-pinned ref so mutable tag changes cannot populate the wrong
  cache entry after lookup.
- `SPOREVM_ROOTFS_CACHE_DIR` is the explicit cache override for direct image
  rootfs outputs.
- Capture belongs on `spore run --capture-on-abort`; do not add a standalone
  `spore capture` command for the first product surface.
- `spore resume SPORE` resumes exactly one spore; fan-out remains explicit via
  `spore fork` plus repeated `spore resume` calls.
- Product `spore resume` now promotes proven backend resume paths and defaults
  RAM size from the spore manifest instead of the harness default.
- The product `--json` final-frame behavior has been removed before 1.0. The
  desired product contract is streaming stdout/stderr plus process exit status.
- The immediate next implementation slice is host-triggered capture from
  `spore run`, because product resume and fresh-run streaming are now in place.
- Resume visibility starts with backend console streaming. Separated
  stdout/stderr after resuming a captured `spore run` requires a later explicit
  reconnect or host-stream state design.

## Open Questions And Recommended Defaults

### Resolved Slice A Defaults

- Managed kernel resolver: start by reusing the existing
  `scripts/ensure-managed-kernel.sh` behavior for the worktree/dev build, but
  keep the dependency explicit and fail with a clear error if the helper is not
  available. Do not present this as a packaged single-binary behavior until the
  resolver is moved into Zig or installed as a supported helper.
- Minimal exec initrd: prefer a build-installed artifact over first-use
  generation. `zig build` should leave the default initrd somewhere `spore run`
  can locate from `zig-out/bin/spore`, while `SPOREVM_RUN_INITRD` remains the
  override.

### Resolved Slice B Defaults

- Kernel profile: use one managed SporeVM run kernel for both minimal initrd
  commands and `--rootfs`. It combines `CONFIG_BLK_DEV_INITRD=y`,
  `CONFIG_VIRTIO_BLK=y`, and `CONFIG_EXT4_FS=y`, avoiding a split between
  cleanroom's separate `initrd` and `rootfs` profiles.
- Rootfs device discovery: prefer mounting `devtmpfs` in the agent and waiting
  for the virtio-blk device node. A fixed `/dev/vda` mknod is acceptable only
  as a temporary smoke fallback if devtmpfs support is missing from the managed
  kernel.

### Safe To Defer

- Direct image cache pruning and garbage collection.
- OCI Entrypoint/Cmd/User/Env/Workdir behavior.
- Trusted same-host RAM backing as a default product resume behavior. Keep the
  first resume surface verified-by-chunks unless the caller explicitly opts into
  local trust.
- Event-stream JSON output for streaming runs.
- Separated stdout/stderr after product `spore resume` if the first
  implementation streams only the guest console.

## Key Learnings From Pressure-Testing

The riskiest scope trap is making direct OCI input the first slice. That would
mix command execution, image resolution, cache invalidation, rootfs mutability,
and runtime metadata before the lower-level rootfs attach path is proven. The
plan therefore starts with default run assets, then read-only `--rootfs`, then
the existing rootfs builder.

The second risk is cache poisoning through writable rootfs mounts. A cached OCI
rootfs must not be mutated by `spore run`, so rootfs execution starts read-only
and writable state is deferred until there is an explicit scratch or overlay
model.

The third risk is a misleading product claim around OCI runtime semantics.
Running an explicit argv from an OCI-derived filesystem is not the same as
implementing Docker semantics. The plan records that boundary and keeps image
metadata behavior in a later slice.

The fourth risk is default asset resolution that only works from a source tree.
The first slice must either make the helper dependency explicitly
development-only or install/generate assets in a way that survives normal
`zig build` output and later package installation.

The current Slice F risk is bundling several different problems into one PR:
product resume, streaming run output, host-triggered snapshot, and resume-time
output visibility. Product resume is still the narrow first slice because the
backend mechanics already exist. Streaming run output should land before
capture-on-abort so the long-running process is visible before it is captured.
Resume-time output needs a separate decision because a host-side vsock stream is
not part of the portable spore.
