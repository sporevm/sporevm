---
status: active
last_reviewed: 2026-07-04
spec_refs:
  - docs/libspore.md
  - docs/lifecycle.md
  - SECURITY.md
  - include/spore.h
  - src/c_api.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/net_gateway.zig
  - src/spore_netd.zig
  - src/main.zig
  - bindings/go/spore.go
---

# Standalone libspore Re-Exec Trampoline

## Summary

`libspore` should be able to run named lifecycle VMs without finding a separate
`spore` CLI on `PATH`. The recommended design keeps the subprocess boundary but
changes the executable from "whatever `spore` resolves to" into the embedder's
own executable, with a small re-exec trampoline that dispatches hidden SporeVM
roles before the embedder's normal main logic runs.

This makes the monitor, `spore-netd`, and library code come from one linked
artifact. The private argv contract between `createNamed`/`resumeNamed`, the
monitor, and `netd` can stay private because both ends are the same version.
Existing CLI behavior stays unchanged: the `spore` binary can still execute
`spore monitor ...` and `spore netd ...` through `src/main.zig`.

The first useful slice is still a version handshake. It protects current
deployments that pass an explicit `spore_executable` or fall back to `"spore"`
while the trampoline work is in progress, and it turns helper skew into an early
failure instead of a late stale VM.

## Problem

Named lifecycle is not self-contained today. `src/lifecycle.zig` starts the
long-lived monitor with:

```console
<spore_executable> monitor <name> --backend ... --memory ... --vcpus ...
```

`src/net_gateway.zig` starts managed networking with:

```console
<spore_executable> netd --stdio --allow-host-port ...
```

The CLI passes its own `argv[0]`, so CLI-spawned helpers normally match the
caller. Embedders do not have that property. The Zig, C, and Go named lifecycle
options all expose `spore_executable`, and the C ABI falls back to `"spore"`
when the field is empty. The Go binding currently forwards the caller's
`SporeExecutable` string and otherwise gets that C default.

That makes monitor and netd flags a hidden cross-binary ABI. A libspore 1.5.0
embedder can accidentally run a 1.3.0 `spore` CLI from `PATH`; create, resume,
and networking may then fail after the library has already reported success or
after the VM has been classified as stale.

## Goals

- Let Go embedders run named lifecycle without installing a separate `spore`
  binary on `PATH`.
- Keep the monitor and netd as real child processes with a fresh exec boundary.
- Cover `createNamed`, `resumeNamed`, and named fork children because they all
  route through `spawnMonitorExecutable` or `startForkChildExecutable`.
- Cover managed networking because monitors and one-shot run/resume paths start
  `spore-netd` through `net_gateway.Process.start`.
- Keep the hidden monitor/netd argv contract internal, unversioned, and free to
  change once both sides are the same artifact.
- Add an early fail-closed helper version check for existing external-helper
  deployments.
- Document macOS signing requirements for embedders that want HVF.
- Preserve the current `spore` CLI UX and hidden subcommands.

## Non-Goals

- No fork-without-exec path. Go and macOS framework state make that the wrong
  boundary.
- No embedded helper binary extraction from `libspore`.
- No central daemon or public monitor protocol.
- No attempt to remove cgo from the Go binding in this plan. The standalone
  outcome is one signed embedder executable after cgo/static linking is solved,
  not `CGO_ENABLED=0`.
- No public support promise for running hidden `monitor` or `netd` commands from
  arbitrary third-party binaries without the SporeVM trampoline environment.
- No Windows support. The named lifecycle backend contract remains HVF on Apple
  Silicon and KVM on Linux/aarch64.

## Current State

- `src/main.zig` dispatches hidden `monitor` and `netd` commands to
  `spore_internal.monitor.cli` and `spore_internal.spore_netd.cli`.
- `src/lifecycle.zig` defaults `CreateNamedOptions.spore_executable`,
  `ResumeNamedOptions.spore_executable`, and `ForkNamedOptions.spore_executable`
  to `"spore"`.
- The C ABI exposes `spore_build_info`, currently with version string and C ABI
  version fields, and the Go binding checks the loaded ABI is new enough during
  `spore.New()`.
- `resumeNamed` in this checkout already calls `waitForReadyResult` after
  spawning the monitor. The incident behavior where resume returned success
  while the VM stayed stale should be treated as fixed in current code, but the
  version handshake still belongs in this plan because readiness does not prove
  helper compatibility.
- The monitor starts optional `spore-netd` before applying the monitor jail.
  After startup, `monitor_jail.zig` denies child process execution through the
  macOS sandbox profile or Linux seccomp filter.
- The current `Ready` metadata records pid, control socket, and console log
  path. It does not record or verify the helper's SporeVM version.

## Progress Snapshot

- Slice 1 is implemented on `lox/libspore-helper-handshake`. Current monitors
  answer a `hello` control request with the shared SporeVM version and helper
  contract.
- `createNamed`, `resumeNamed`, and named fork children verify `hello` during
  readiness waiting. Missing support, wrong schema, wrong version, or wrong
  helper contract fail closed as `MonitorVersionMismatch`.
- Exec, copy, suspend, snapshot, and streaming exec/copy verify `hello` before
  sending their operation-specific control request.
- `rm` intentionally remains cleanup-oriented: it sends `shutdown` without a
  prior `hello` check so an old or mismatched monitor can still be removed.
- Slice 2 is implemented on the same branch. The C ABI now exports
  `spore_reexec_main` with `SPORE_REEXEC_CONTRACT_VERSION`, and the CLI and C
  ABI call shared internal monitor/netd role entrypoints.
- Re-exec children are gated by `SPORE_REEXEC_ROLE`,
  `SPORE_REEXEC_CONTRACT`, and `argv[1]`. Unsupported contracts, missing
  markers, and role mismatches fail closed before monitor or netd code runs.
- The dispatcher unsets the re-exec markers and closes unexpected file
  descriptors greater than `2` before entering the role body.

## Recommended Design

### Process Model

Keep the same process tree:

```text
embedder process
  -> re-exec embedder as monitor role
       -> optional re-exec embedder as netd role
```

The parent still uses `std.process.spawn` for monitor and netd. The change is
the executable and a role marker in the child environment:

```text
SPORE_REEXEC_ROLE=monitor
SPORE_REEXEC_CONTRACT=1
argv[0] = /absolute/path/to/embedder
argv[1] = monitor
argv[2...] = existing private monitor flags
```

For netd:

```text
SPORE_REEXEC_ROLE=netd
SPORE_REEXEC_CONTRACT=1
argv[0] = /absolute/path/to/embedder
argv[1] = netd
argv[2...] = existing private netd flags
```

The role environment prevents accidental dispatch when a user runs an embedder
with `monitor` as a normal argument. The dispatcher also verifies that the role
matches `argv[1]`, unsets the re-exec environment before role code runs, and
exits without reaching the embedder's main.

### C ABI Sketch

Use one exported dispatcher, not separate exported mains. One symbol keeps the
ABI small and lets future hidden roles reuse the same gate without adding more
public entry points.

```c
#define SPORE_REEXEC_CONTRACT_VERSION 1u

/*
 * Runs a hidden SporeVM re-exec role selected by SPORE_REEXEC_ROLE.
 *
 * Returns SPORE_INVALID_VALUE when argv/env do not describe a SporeVM re-exec
 * child. On success, out_exit_code is the role's process exit code. Long-lived
 * monitor roles normally do not return until the VM exits.
 */
SPORE_API SporeResult spore_reexec_main(
    int argc,
    const char *const *argv,
    int *out_exit_code);
```

The exported function should not take `SporeContext`. It is a process entry
point, not a product API call. It uses the process stdin/stdout/stderr,
process environment, and argv supplied by the embedding runtime.

Internally, refactor the existing hidden role implementations so both
`src/main.zig` and `spore_reexec_main` call the same monitor/netd entrypoints.
Do not duplicate CLI parsing in the C ABI layer.

### Go Binding Trampoline

The Go binding should provide the default trampoline for Go embedders:

- Package init checks `SPORE_REEXEC_ROLE`.
- If unset, init returns normally.
- If set, init builds a C argv from `os.Args`, calls `spore_reexec_main`, and
  exits the process with the returned role exit code.
- `CreateNamed`, `ResumeNamed`, and `ForkNamed` fill `SporeExecutable` with the
  current executable path when the caller leaves it empty.
- Callers can still set `SporeExecutable` explicitly to use an external helper
  during migration or debugging.

Use Go stdlib `os.Executable()` for the self path. It maps to the platform
mechanisms SporeVM cares about (`/proc/self/exe` on Linux and
`_NSGetExecutablePath` on macOS) without adding platform-specific code in the
binding. Resolve symlinks before passing the path to libspore so diagnostics
show the real signed executable.

Go init is not a hardening boundary. Other imported packages may have init-time
side effects before the SporeVM package runs. The design goal is version
self-containment and distribution simplicity, not reducing the monitor address
space below the standalone `spore` CLI. Embedders that need a tiny, independent
VMM binary can keep using `SporeExecutable`.

### CLI Compatibility

The `spore` CLI keeps accepting hidden `monitor` and `netd` subcommands. It does
not need to go through the C ABI dispatcher to satisfy this plan. The important
implementation rule is that CLI hidden commands and re-exec hidden commands
share one internal parser and role body.

### macOS Entitlements

With the external CLI model, the shipped `spore` executable is signed with
`spore.entitlements` and carries `com.apple.security.hypervisor`.

With the trampoline model, the monitor process is the embedder executable, so
the embedder executable must be signed with the hypervisor entitlement. Signing
`libspore.dylib` is not enough because the entitlement is checked on the
process executable. Static Go embedders need to codesign the final binary after
linking. Dynamic embedders need both a loadable libspore and a signed final
executable.

`spore-netd` does not need the hypervisor entitlement, but it will run as the
same signed embedder executable in netd role.

### Monitor Jail And File Descriptors

Re-exec gives the monitor a fresh address space, but it does not by itself prove
the file descriptor table is clean. Exec preserves descriptors that are not
close-on-exec. That matters because SporeVM's security model says secrets do
not enter the VMM process.

The standalone implementation should therefore make descriptor inheritance an
explicit invariant:

- Spore-owned host fds remain opened with `CLOEXEC` unless they are deliberately
  passed as stdio.
- The re-exec dispatcher closes unexpected fds greater than `2` before entering
  monitor or netd role, using `close_range` on Linux and `closefrom` or a bounded
  close loop on macOS.
- Netd keeps only stdin, stdout, and stderr because its frame stream and ready
  signal use those descriptors.
- The monitor keeps only stdio at entry, then opens kernel, initrd, rootfs,
  runtime metadata, control socket, and optional netd pipes itself.

The monitor jail remains in the same place: after optional startup helpers are
spawned and before monitor-controlled guest work begins. The existing
`mise run smoke:monitor-jail` remains the behavioral proof that post-startup
exec is denied.

### Helper Version Handshake

Add a monitor control request before or during readiness wait:

```json
{"type":"hello"}
```

Response:

```json
{
  "type": "hello",
  "schema": "spore.monitor.hello.v1",
  "spore_version": "1.5.0",
  "helper_contract": 1
}
```

`waitForReadyResult` should wait for the ready file, connect to the control
socket, send `hello`, and fail closed when the version or helper contract does
not match the libspore build. Missing `hello` support is a mismatch. That makes
new libspore plus old PATH helper fail during `createNamed`, `resumeNamed`, and
named fork child startup.

Existing already-running monitors should also be checked before exec, copy,
suspend, snapshot, and streaming exec requests. Reuse one helper that connects,
performs `hello`, then sends the requested control message so version skew does
not surface as `NamedVmNotReady` or a generic bad response. Keep `rm` as a
best-effort cleanup operation so a mismatched old monitor does not become
impossible to remove.

## Delivery Strategy

### Slice 1: Helper Handshake

Add the monitor `hello` request and require it in lifecycle control paths.

Definition of done:

- `createNamed`, `resumeNamed`, and named fork children fail with a clear
  version mismatch when the spawned monitor omits or reports the wrong version.
- Exec/copy/suspend/snapshot paths reject already-running mismatched monitors
  before sending operation-specific requests; `rm` remains cleanup-only.
- Existing current-version CLI helpers still pass.
- Tests cover current, missing, and wrong helper version responses.

This slice protects users immediately and does not require Go trampoline work.

### Slice 2: Re-Exec Dispatcher ABI

Export `spore_reexec_main`, add `SPORE_REEXEC_CONTRACT_VERSION` to
`include/spore.h`, and refactor hidden monitor/netd entrypoints so the CLI and
C ABI share role code.

Status: implemented on `lox/libspore-helper-handshake`.

Definition of done:

- Calling `spore_reexec_main` with `SPORE_REEXEC_ROLE=netd` and `netd --stdio`
  reaches the existing netd parser.
- Calling it with `SPORE_REEXEC_ROLE=monitor` reaches the existing monitor
  parser.
- Missing env, mismatched env/argv, and unsupported contract versions fail
  closed.
- Descriptor cleanup is covered by a focused smoke or unit harness.

### Slice 3: Go Trampoline And Self Executable Default

Teach `bindings/go` to dispatch re-exec children in package init and to fill
empty `SporeExecutable` with the current executable path for named lifecycle
operations.

Definition of done:

- Go `CreateNamed`, `ResumeNamed`, and named fork use the embedder path when the
  caller leaves `SporeExecutable` empty.
- Explicit `SporeExecutable` continues to override the default.
- A small Go test binary can spawn itself in netd re-exec role and observe the
  role entry without running the test main.
- The binding docs explain macOS signing and the external-helper escape hatch.

### Slice 4: End-To-End Named Lifecycle Proof

Add an integration smoke that builds a tiny Go embedder, starts a named VM
without `spore` on `PATH`, executes a command, and removes the VM.

Definition of done:

- The smoke proves no PATH-resolved `spore` is needed.
- A network-enabled variant proves monitor-spawned netd also re-execs through
  the embedder.
- macOS HVF smoke documents the required codesign command or skips with a clear
  entitlement message.
- Linux KVM smoke proves the same path on a host with `/dev/kvm`.

### Slice 5: Consumer Documentation

Update `docs/libspore.md` and the Go binding examples.

Definition of done:

- The default Go example no longer sets `SporeExecutable`.
- The C/Zig docs still describe explicit `spore_executable` because non-Go
  embedders must install their own trampoline before using self re-exec.
- Troubleshooting covers PATH fallback, version mismatch errors, macOS
  entitlement failures, and dynamic library load failures.

## Verification

- `mise run test`
- `mise run build`
- `mise run smoke:monitor-jail`
- `mise run smoke:monitor-failure-modes`
- Focused C ABI tests for `spore_reexec_main` env/argv validation.
- Focused lifecycle tests for monitor `hello` success, missing support, and
  version mismatch.
- Go binding tests for `os.Executable` defaulting and explicit
  `SporeExecutable` override.
- End-to-end Go embedder smoke on macOS HVF with codesign entitlement.
- End-to-end Go embedder smoke on Linux KVM.

## Decisions

- Use one exported re-exec dispatcher instead of separate `spore_monitor_main`
  and `spore_netd_main` symbols.
- Keep hidden monitor/netd argv private. The public ABI is only the dispatcher
  and the role environment contract.
- Make Go standalone behavior the default when `SporeExecutable` is empty.
- Keep explicit `SporeExecutable` as the escape hatch for external helper mode.
- Ship the version handshake before the trampoline.
- Treat current `resumeNamed` readiness waiting as already fixed in this
  checkout; do not create a separate resume-readiness plan unless testing finds
  another path that returns before readiness.

## Rejected Alternatives

- **Version handshake only.** Useful first slice, but it still requires a
  same-version helper binary on PATH or at a configured path.
- **Embed the monitor binary in libspore.** Linux could use `memfd_create` plus
  `fexecve`, but macOS would need a temporary executable and signing story. It
  adds binary extraction, cache cleanup, and code-signing complexity for no
  product gain over re-exec.
- **Fork without exec.** This is not acceptable for Go embedders, macOS
  framework state, or SporeVM's monitor isolation boundary.
- **Make monitor/netd public commands for embedders.** That preserves the
  hidden cross-binary contract instead of removing it.

## Deferred Work

- A pure-C helper for non-Go embedders to discover their executable path. C
  embedders can pass an explicit path until a real user needs a portable helper.
- Removing cgo from the Go binding. This plan assumes libspore is linked into
  the embedder.
- Making the `spore` CLI itself call the C ABI dispatcher. Shared role code is
  enough; forcing the CLI through the public C symbol is not needed.
- More granular helper contract negotiation. Same-version matching is the
  smallest safe rule until there is a demonstrated need for cross-version
  helpers.

## Key Learnings From Pressure-Testing

- The risky part is not argv dispatch; it is accidentally treating `exec` as a
  complete security reset. The plan now requires explicit fd cleanup and smokes
  for descriptor inheritance.
- Go init-time dispatch prevents the embedder's main from running, but it does
  not promise a tiny process image. The plan records that standalone mode is a
  distribution and skew fix, not a stricter monitor hardening mode.
- The handshake should land first because it protects current external-helper
  deployments and gives the trampoline a clear failure mode during rollout.
