---
status: active
last_reviewed: 2026-07-10
spec_refs:
  - docs/lifecycle.md
  - docs/libspore.md
  - docs/spore-format.md
  - SECURITY.md
  - src/lifecycle.zig
  - src/c_api.zig
  - bindings/go/spore.go
---

# Named Lifecycle Contract Follow-Up

## Current Contract

The monitor startup hardening and Go re-exec trampoline have landed. Named
startup waits for `ready.json`, a live PID, and a `control.sock` `hello`
response with the `spore.monitor.hello.v1` schema, exact SporeVM version, and
helper contract. Control operations re-check the handshake before sending
operation-specific requests, except cleanup-oriented shutdown.

The monitor now publishes `ready.json` only after the guest agent answers a
dedicated readiness request. Named restore therefore returns exec-ready and its
machine result reports preparation, monitor-spawn, readiness-wait, and total
timings; callers no longer probe readiness with `exec /bin/true`.

The durable contract lives in:

- `docs/lifecycle.md` for monitor readiness, diagnostics, exact argv, and save
  annotation behavior.
- `docs/libspore.md` for Zig/C helper selection and Go self re-exec behavior.
- `SECURITY.md` for the monitor control-socket attack surface.

## Remaining Work

- Make buffered named exec JSON byte-safe for invalid UTF-8 stdout/stderr. The
  monitor already sends `stdout_b64` and `stderr_b64`; the public JSON producer
  still needs a lossless shape, either byte arrays or documented base64 fields.
- Add a Zig/C/Go round-trip check proving invalid UTF-8 survives buffered named
  exec decode. The streaming exec path is already the answer for long or
  interactive output.
- Add or tighten a snapshot annotation merge test for overlay-wins semantics.
  The user-facing docs already state that save-time annotations merge into the
  manifest without dropping create-time annotations.

## Done When

- Invalid UTF-8 bytes survive monitor, Zig, C JSON, and Go decode.
- Buffered truncation flags still work for small-command callers.
- Annotation merge-through-snapshot is pinned by a focused test.

## Non-Goals

- No same-minor monitor compatibility policy.
- No new monitor daemon or public control protocol.
- No replacement for `openExecNamedStream`.
