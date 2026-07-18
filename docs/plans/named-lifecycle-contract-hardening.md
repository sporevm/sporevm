---
status: landed
last_reviewed: 2026-07-19
spec_refs:
  - docs/lifecycle.md
  - docs/libspore.md
  - docs/rootfs.md
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

Image-created named VMs now retain OCI `Config.Env` and `WorkingDir` as their
default command context. The monitor applies that context to detached startup
and every normal, interactive, and TTY exec, while per-exec `--env` and
`--workdir` values override one request without changing the live defaults.
Bare inherited OCI environment entries are matched by their full key, so an
explicit `KEY=` reliably replaces them with an empty value.

The defaults live in host-private lifecycle metadata while the VM is running
and in bounded optional `exec_defaults` manifest metadata across save, restore,
offline fork, bundle transport, and live named fork. Per-exec values are not
copied into either metadata surface; ordinary guest RAM and rootfs snapshot
semantics still apply to any value observed by the workload.

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
- Image command defaults survive monitor publication, live and offline fork,
  save/restore, and bundle transport on both manifest versions.
- Normal, detached, interactive, and TTY named exec paths share one default and
  override merge, including explicit empty values and bare inherited OCI keys.

## Key Learnings From Pressure-Testing

The pinned Zig JSON encoder already had the smallest compatible lossless shape:
it writes valid byte slices as strings and invalid UTF-8 slices as integer
arrays. Documenting and testing that behavior avoids duplicate base64 fields
and leaves valid-text consumers unchanged. The annotation regression belongs at
the monitor publication boundary, where lifecycle metadata replaces the
captured manifest annotations.

Named exec defaults follow the same ownership boundary: the monitor owns the
effective request merge, lifecycle metadata owns live compatibility, and the
portable manifest owns save and fork persistence. Request-local values must
stay out of both metadata surfaces, but they cannot be described as absent from
future snapshots after the guest workload has observed them.

## Non-Goals

- No same-minor monitor compatibility policy.
- No new monitor daemon or public control protocol.
- No replacement for `openExecNamedStream`.
