---
status: active
last_reviewed: 2026-07-23
spec_refs:
  - docs/automation.md
  - docs/libspore.md
  - src/machine_output.zig
  - src/run.zig
  - include/spore.h
  - bindings/go/spore.go
---

# Automation contract hardening

## Summary

Issue #549 closes the gap between command-specific JSON, runtime JSONL, and the
C/Go/Zig terminal models. The implementation reuses the existing product API
and failure classifier, then makes adapters preserve that information instead
of creating a second framework.

## Scope

The public bounded inventory is version, host and spore inspection, system and
cache operations, rootfs and image operations, build, named lifecycle and copy,
and bundle fork/pack/unpack/push/inspect/pull. The streaming inventory is run,
attach, restore, exec, and fanout. Internal monitor and netd roles are excluded.

The command-by-command inventory is:

| Model | CLI operations | Terminal contract |
| --- | --- | --- |
| Bounded | `version`, `host-info`, `inspect`, artifact and named `fork`, `pack`, `unpack`, `push`, `inspect-bundle`, `pull` | One versioned result under global `--json` |
| Bounded | `system df`, `system prune`, `cache gc`, `cache pins`, `cache unpin` | One versioned result under global `--json` |
| Bounded | `rootfs build`, `rootfs import-oci`, `rootfs import-tar`, `rootfs resolve`, `rootfs cas-preload`, `image pull`, `image export-fixture`, `build` | One versioned result under global `--json` |
| Bounded | `create`, `copy-in`, `copy-out`, `save`, `rm`, `ls`/`ps`, and restore without event mode | One versioned result under global `--json` |
| Streaming | `run`, `attach`, restore with event mode, `exec`, `fanout` | Versioned JSONL followed by one completion |

The overlapping terminal models are Zig `RunEvent`/`ExecNamedStreamEvent`, C
`SporeExecNamedStreamEvent`, and Go `ExecNamedStreamEvent`. Zig keeps its typed
`.exit` and `.failure` variants as the product model; the automation serializer
and C/Go adapters project those into `completed`, `failed`, or `canceled`
completion outcomes. C `SporeResult` and Go `CallError` retain their transport
status while exposing the same `spore.error.v1` body used by CLI failures.

Initial create-log retention (#552), resource-oriented aliases (#553), and
unrelated behavior changes are explicit non-goals.

## Delivery strategy

1. Land the shared failure taxonomy, retry classes, terminal outcomes, and
   schema-versioned bounded result types.
2. Align CLI bounded output and JSONL completion records without changing human
   output defaults.
3. Align C and Go failure/completion adapters, advancing the C ABI once.
4. Update durable docs, release notes, and contract tests; validate setup,
   runtime, cancellation, and interruption behavior.

## Verification

- Unit snapshots pin bounded schemas, stable failure triples, and completion
  records for completed, failed, and canceled streams.
- Event-sink and transport tests prove an interrupted stream cannot look
  complete.
- C and Go tests prove the same failure body and named-exec completion semantics.
- `mise run test` and `mise run docs` cover repository-wide integration.

## Resolved decisions

- Keep command-owned result payloads and schema names; a generic payload wrapper
  would add nesting without improving bounded terminal detection.
- Use one common `spore.automation.event.v1` envelope and `completion` record for
  streams.
- Preserve `retryable` as a compatibility projection while `retry` carries the
  stable three-way classification.
- Treat premature EOF as interruption, not cancellation or runtime failure,
  because the producer may still have completed the operation.

## Key learnings from pressure-testing

The main risk was adapter drift rather than missing infrastructure. Centralizing
new semantics in `machine_output.zig` avoids parallel taxonomies, and explicit
completion prevents output EOF or guest exit codes from being mistaken for a
SporeVM failure. Interruption remains `unknown` retry because automatically
repeating a side-effecting operation could duplicate work.
