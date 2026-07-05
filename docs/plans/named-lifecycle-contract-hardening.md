---
status: active
last_reviewed: 2026-07-04
spec_refs:
  - docs/lifecycle.md
  - docs/libspore.md
  - docs/spore-format.md
  - SECURITY.md
  - src/lifecycle.zig
  - src/monitor.zig
  - src/c_api.zig
  - bindings/go/spore.go
  - bindings/go/types.go
related_plans:
  - docs/plans/interactive-input-tty.md
---

# Named Lifecycle Contract Hardening

## Summary

SporeVM named lifecycle calls should fail before reporting success when the
spawned monitor is not the monitor the caller can safely use. The monitor
startup contract needs to prove three things before `createNamed`,
`restoreNamed`, or named fork children return: the process is alive, the control
socket is accepting requests, and the spawned `spore` executable is the same
version as the linked `libspore`.

The operator outcome is boring: if a PATH-resolved `spore` binary is stale, or a
restored monitor never becomes usable, CLI and libspore callers get an error
that names the VM state, PID, console log path, and monitor log path instead of
only seeing `NamedVmNotReady` on the next exec.

This work is independent from exported monitor/netd entry points and any
re-exec trampoline. It may resolve `spore_executable` to a concrete binary path
before spawning, but it must not add or reshape exported entry points.

## Problem

The named lifecycle monitor protocol is a private same-version agreement between
`libspore` and the `spore monitor` executable. Embedders often leave
`spore_executable` as `spore`, so PATH can select an older executable than the
loaded library. That can produce a monitor that gets far enough to leave runtime
state behind but not far enough to support the current control protocol.

The current code already has a startup wait in `createNamed`, `restoreNamed`, and
fork-child startup, but that wait only proves a readable `ready.json` and a live
PID. It does not prove that `control.sock` speaks the same protocol version as
the library. Follow-up failures then collapse into `NamedVmNotReady` without the
state and log paths that `spore ls` can show.

The buffered exec JSON result has a separate contract gap. The monitor captures
bounded stdout/stderr and the C/Go JSON surface treats output as text, while the
monitor's internal response already uses base64. Long output should use the
existing streaming exec path, and binary output from the buffered path must not
be UTF-8 substituted.

## Goals

- Make monitor startup fail closed for create, resume, and fork-child startup.
- Add a control-socket version handshake before named startup reports success.
- Require exact `libspore.version == spore executable version` for the private
  monitor argv/control contract.
- Include both versions and the resolved executable path in mismatch errors.
- Make lifecycle errors carry last known VM state, PID, console log path, and
  monitor log path for CLI and libspore callers.
- Make the Go binding default `SporeExecutable` to `"spore"` explicitly instead
  of relying on the C ABI's empty-string default.
- Preserve the existing streaming exec ABI and Go wrapper; add tests and docs
  around when callers should use it.
- Make buffered exec JSON lossless for non-UTF-8 stdout/stderr.
- Promote annotation merge-through-snapshot and guest exec's no-PATH-lookup
  behavior into docs.

## Non-Goals

- No exported monitor or netd entry-point work.
- No re-exec trampoline or bindings trampoline design.
- No implicit guest PATH lookup. Bare `sh` remains a guest `execve("sh", ...)`
  failure.
- No new monitor daemon, registry database, or public TCP control protocol.
- No same-minor compatibility claim for the monitor control protocol.
- No replacement for the existing `openExecNamedStream` C ABI and Go streaming
  surface unless implementation evidence proves it is incomplete.

## Target Model

### Startup Readiness

All named monitor startup flows use one helper after spawn:

1. Resolve the requested `spore_executable` to the path that will be spawned.
2. Spawn `spore monitor ...` with the existing argv contract.
3. Wait for `ready.json` and a live PID.
4. Connect to the known `control.sock`.
5. Send a small local-only handshake request, for example:

```json
{"type":"hello"}
```

The monitor responds with its executable version:

```json
{"type":"hello","version":"1.5.0"}
```

The library compares that value with `libspore.version`. A mismatch returns an
error shaped like:

```text
libspore 1.5.0 cannot use spore executable 1.3.0 at /usr/local/bin/spore
```

Exact version matching is the contract. The monitor argv and control protocol
are private, not a documented compatibility API. Same-minor matching can be
introduced later only with an explicit compatibility matrix and tests for each
accepted pair.

### Diagnostics

Named lifecycle operations should attach the same facts to readiness and
not-ready failures:

- VM name;
- last known lifecycle state: `absent`, `incomplete`, `ready`, or `stale`;
- recorded PID when present;
- `console.log` path;
- monitor log path when present;
- `control.sock` path when useful;
- resolved `spore_executable` path for startup failures.

The CLI should print those facts in human mode and include them in `--json`
error output where machine-output helpers already exist.

For libspore, the smallest useful surface is to keep `spore_context_last_error`
human-readable and add one structured last-error detail JSON accessor only if a
plain message cannot carry the required fields through the Go binding cleanly.
The Go binding should expose those fields through `CallError` without changing
successful result structs.

### Exec Output

The existing streaming path remains the answer for long-running or unbounded
exec output:

- Zig: `openExecNamedStream`
- C ABI: `spore_exec_named_stream_open` and stream event functions
- Go: `OpenExecNamedStream`

The buffered path remains for small commands, but its JSON output must be
lossless. The monitor already returns base64 internally (`stdout_b64`,
`stderr_b64`, `network_events_jsonl_b64`); the C JSON payload should either emit
byte arrays for `stdout`/`stderr` or documented base64 fields. The Go binding
already accepts byte arrays in `ExecNamedResult.UnmarshalJSON`, so the smallest
compatible producer change is to emit byte arrays and keep the old string
decoder for older libraries.

### Format Documentation

`saveNamed` merges overlay annotations into the captured manifest
annotations. This is a contract:

- create-time annotations survive snapshots;
- snapshot overlay annotations win on key collisions;
- unknown annotation keys stay opaque and are still subject to the existing
  validation and size limits.

Guest exec uses `execve(argv[0], ...)` and does no guest PATH lookup. Exact argv
callers must pass `/bin/sh`, not `sh`. Shell-form CLI calls continue to construct
an explicit shell argv at the host side when that is the documented command
form.

## Safety Model

- Named lifecycle remains a local monitor boundary protected by private runtime
  directory permissions.
- Unknown control requests continue to fail closed.
- Handshake failures must not leave a VM reported as successfully created,
  resumed, or forked.
- Version mismatch is a startup error, not a warning.
- Diagnostics may reveal local paths to the caller that owns the process, but
  must not expose guest secrets or widen runtime-directory permissions.
- Binary exec output is workload data; it must cross Zig, C, Go, and JSON
  boundaries without interpretation as UTF-8.

## Current State

- `src/libspore.zig` and `src/root.zig` both report `1.5.0`.
- `build.zig.zon` is package metadata at `0.0.0`; it is not the handshake
  source.
- PR 1 is implemented locally on `lox/named-lifecycle-readiness`: `createNamed`,
  `restoreNamed`, and `startForkChildExecutable` all wait for a live PID plus a
  versioned monitor `hello` response before reporting success.
- `spawnMonitorExecutable` resolves the requested `spore_executable`, probes
  `spore version`, exact-matches it against `libspore.version`, and captures
  monitor stdout/stderr in `monitor.log`.
- C ABI create/resume/fork defaults empty `spore_executable` to `"spore"`.
- The Go binding now defaults empty `SporeExecutable` to `"spore"` before
  crossing the C ABI.
- Named lifecycle failures now populate the lifecycle last-error text with VM
  state, PID, console log, monitor log, and control socket details.
- `openExecNamedStream` and the matching C/Go stream APIs already exist.
- The monitor's bounded exec response is internally base64, while the public
  JSON shape still exposes `stdout` and `stderr` as text-like fields.
- `saveNamed` already merges annotation overlays into captured manifests.
- The guest agent uses `execve(argv[0], ...)` and therefore performs no PATH
  search.

## Delivery Strategy

### PR 1: Named Lifecycle Robustness

Scope:

- add a failing startup-readiness test where `ready.json` exists but the monitor
  is unusable or version-mismatched;
- add a monitor `hello` control request;
- replace the file/PID-only wait with a shared startup readiness helper for
  create, resume, and fork-child startup;
- resolve the executable path before spawn so mismatch errors name the actual
  binary where possible;
- enrich CLI and libspore error diagnostics for named lifecycle failures;
- make the Go binding default `SporeExecutable` to `"spore"` explicitly;
- document exact-version matching in `docs/lifecycle.md` and `docs/libspore.md`;
- update `SECURITY.md` for the added local control-socket handshake.

Definition of done:

- stale or mismatched monitors return startup errors from create/resume/fork
  instead of success;
- mismatch errors include both versions and the executable path;
- Go callers can inspect a useful `CallError`;
- `mise run test` and `mise run build` pass.

### PR 2: Exec Fidelity

Scope:

- pin the existing streaming exec surface with C and Go tests if coverage is
  missing;
- make the buffered exec JSON producer emit lossless bytes for stdout/stderr;
- keep Go's existing string-or-byte-array decoder for compatibility;
- add a round-trip test with invalid UTF-8 bytes;
- document buffered versus streaming exec in `docs/libspore.md` and
  `docs/lifecycle.md`.

Definition of done:

- invalid UTF-8 bytes survive monitor, Zig, C JSON, and Go decode;
- long-output guidance points callers to `openExecNamedStream`;
- buffered truncation flags still work for small-command callers;
- `mise run test`, Go binding tests, and `mise run build` pass.

### PR 3: Contract Documentation And Pinning Tests

Scope:

- document annotation merge-through-snapshot in `docs/spore-format.md` and
  `docs/lifecycle.md`;
- add or tighten a snapshot annotation merge test, including overlay-wins key
  collision semantics;
- document no guest PATH lookup for exact exec argv;
- keep exit-127 hints in the guest `execve` failure path without host PATH
  lookup, so both shell-form and exact argv failures stream useful stderr.

Definition of done:

- docs state the annotation guarantee and PATH behavior directly;
- tests pin overlay-wins merge semantics;
- bare `sh` failure remains a guest failure, not a host-side resolver feature;
- missing initrd commands explain that callers need `--image`, `--rootfs`, or a
  command-capable initrd;
- `mise run test` and `mise run build` pass.

## Verification

Run these for every PR:

```bash
mise run test
mise run build
```

Focused checks by PR:

- PR 1: unit tests for readiness handshake, version mismatch, diagnostic detail,
  Go default executable selection, and C ABI last-error behavior.
- PR 2: Zig/C JSON round-trip for invalid UTF-8, Go `ExecNamedResult` decode for
  produced byte arrays, and existing fake-monitor stream tests.
- PR 3: snapshot annotation merge test and docs-only validation through the
  normal build/test gate.

Use runtime smoke only when the touched slice changes real monitor behavior:

```bash
mise run smoke:lifecycle
mise run smoke:lifecycle-tty
mise run smoke:monitor-failure-modes
```

## Resolved Decisions

- Use exact version matching for `libspore` and the spawned `spore` executable.
- Report the executable version over the local monitor control socket, not by
  trusting package metadata.
- Reuse the existing streaming exec ABI instead of adding a second streaming
  abstraction.
- Preserve no-PATH-lookup guest exec semantics.
- Keep this work out of exported entry-point and trampoline design.

## Deferred Work

- Same-minor or ABI-version compatibility can be reconsidered only after the
  monitor argv/control protocol has a compatibility matrix.
- A richer typed C ABI error-detail struct can replace JSON detail if multiple
  bindings need it.
- More ergonomic guest PATH hints can be added after the exact argv failure
  shape is proven useful.

## Key Learnings From Pressure-Testing

- A file/PID readiness wait is too weak. The readiness proof must touch
  `control.sock`, because that is the protocol later exec/snapshot/fork calls
  depend on.
- Adding a compatibility policy would be more code than the private protocol can
  justify. Exact version equality is the smaller and safer rule.
- The streaming exec requirement is partly landed already. The risk is duplicate
  API work; PR 2 should pin and document the existing stream path, then fix the
  buffered binary contract.
- Diagnostics should be attached at the named lifecycle boundary, not patched
  into each caller. Create, exec, resume, fork, copy, snapshot, suspend, and rm
  all classify VM state through the same runtime metadata.

## Reconciliation With Standalone Libspore Reexec

The handshake slice merged into the reexec plan's wire shape
(`spore.monitor.hello.v1` + `helper_contract`), replacing this plan's
version-only hello. This plan's surviving contributions: the pre-spawn
`spore version` probe with the both-versions-and-path error message (skipped
when the resolved executable is the current process), startup and per-call
diagnostics through `lastLifecycleErrorMessage`, and `monitor.log`. The Go
`SporeExecutable` default is the current executable path from the reexec
trampoline, not `"spore"`. Remaining open slices: buffered exec byte-safety
and the annotation-merge / no-PATH-lookup doc promotions.
