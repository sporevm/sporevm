---
status: complete
last_reviewed: 2026-07-23
spec_refs:
  - docs/lifecycle.md
  - docs/libspore.md
  - docs/automation.md
  - src/api.zig
  - src/main.zig
---

# Lifecycle resource vocabulary

Issues #546 and #553 make lifecycle operations discoverable without collapsing
distinct behavior. A live VM is monitor-backed runtime state, a checkpoint
(also called a spore) is saved machine state, an image is application
filesystem plus OCI execution metadata, and a bundle is a portable checkpoint
transport encoding.

Checkpoint inspection exposes `resource_type`, `can_attach`, `can_run_from`,
sessions with per-session stream support, portability, and ownership. Bundle
inspection and lifecycle results carry additive resource types under their
existing v1 schemas. `runFromSpore` requires a new command; `attachSpore` is
the only public Zig operation that selects a saved session.

The CLI adds resource-oriented `vm rm`, `vm fork`, `checkpoint rm`, and
`checkpoint fork` forms. The original flag-dependent spellings remain
compatible throughout the 0.x release line so existing automation has a
documented migration window.

## Verification

- Zig inspection and serialization tests cover resource types, portability,
  lifecycle capabilities, and the empty-command run-from rejection.
- CLI tests and help probes cover both resource namespaces and legacy forms.
- C and Go contract tests cover additive inspection and lifecycle fields.
- `mise run check` and `mise run docs` cover the repository integration.
- Independent deep-analysis review covered grouped-command diagnostics, stable
  automation envelopes, attach failure classification, and binding parity.

## Resolved decisions

- Resource namespaces are aliases over existing operations, not new behavior.
- A checkpoint keeps the existing `.spore` directory format and ownership
  classes; the public type name does not imply self-contained storage.
- Existing schema names and terminal-event envelopes remain unchanged.
- Compatibility forms can be reconsidered for 1.0 only with release-note and
  migration guidance.

## Key Learnings From Pressure-Testing

One generic `rm` or `fork` abstraction would hide the ownership distinction
this track is meant to expose. Resource namespaces keep the implementations
shared while making reviews and scripts name the destructive target directly.
