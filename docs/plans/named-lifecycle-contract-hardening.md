---
status: landed
last_reviewed: 2026-07-13
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

Plain attached named exec now uses the existing SPIO streaming request with
stdin closed by default. `-i` controls stdin forwarding and `-t` controls PTY
allocation. The bounded compatibility collector fails with
`ExecOutputTruncated` instead of returning partial output as success.

The bounded result keeps valid UTF-8 output as JSON strings and emits invalid
UTF-8 output as integer byte arrays. Zig exposes the decoded owned byte slices,
the C ABI returns the lossless hybrid JSON shape, and Go accepts either form
without changing the bytes. Streaming exec remains unchanged.

Snapshot publication coverage now begins with create-time annotations, applies
save-time annotations, runs the actual monitor publication step, and verifies
that create-only keys survive, save-only keys are added, and save-time values
win collisions in the visible manifest.

## Completion Evidence

- Invalid UTF-8 fixtures survive monitor base64 decode, Zig owned slices, C
  JSON byte arrays, and Go decode.
- Existing valid UTF-8 fixtures remain JSON strings.
- Bounded collection still reports truncation as an error rather than partial
  success.
- Annotation overlay semantics are pinned through actual snapshot publication.

## Key Learnings From Pressure-Testing

The pinned Zig JSON encoder already had the smallest compatible lossless shape:
it writes valid byte slices as strings and invalid UTF-8 slices as integer
arrays. Documenting and testing that behavior avoids duplicate base64 fields
and leaves valid-text consumers unchanged. The annotation regression belongs at
the monitor publication boundary, where lifecycle metadata replaces the
captured manifest annotations.

## Non-Goals

- No same-minor monitor compatibility policy.
- No new monitor daemon or public control protocol.
- No replacement for `openExecNamedStream`.
