---
status: active
last_reviewed: 2026-06-26
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/distribution.md
  - docs/spore-format.md
  - src/main.zig
  - src/platform.zig
  - src/bundle.zig
  - src/run.zig
  - src/resume.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/distribution.md
---

# Machine Interfaces Plan

## Summary

SporeVM needs a stable machine interface that is useful from scripts, services,
tests, and future embedded callers without making the CLI the only architecture
boundary. The first public contract should remain process-based: commands accept
normal arguments, single-result commands default to human output, and
`spore --json <command>` is the only one-document machine-output mode.

The implementation should be factored as though a library transport exists:
command handlers call product APIs, product APIs return typed result structs,
and the CLI is one serializer over those structs. The source-level Zig module is
published as `libspore` first; a future C ABI can then wrap the same APIs without
re-defining behavior or exposing raw Zig structs as a public ABI.

This plan deliberately keeps the contract SporeVM-native. The abstractions are
host facts, bundle inspection, materialization, run/resume lifecycle events,
cache roots, and classified failures. They should compose with any caller that
can execute a process or embed a C ABI, without naming a particular higher-level
system in the product contract.

## Problem

Several SporeVM commands already emit JSON, but the behavior is not one coherent
machine interface:

- some commands are always JSON;
- some commands have command-local `--json`;
- runtime output and result output are mixed differently by command;
- error classification is mostly internal Zig error names;
- typed result structs live with the implementation but are not clearly owned as
  product contracts;
- a future embedding surface would either duplicate CLI behavior or depend on
  command parsing details.

The repository is still pre-1.0, so this plan should use a breaking
normalization rather than preserve ad hoc output compatibility. Without a single
model, callers learn command-specific conventions and then carry those
conventions forever. That makes it harder to tighten error handling, add event
streams, or expose a library transport later.

## Goals

- Define one global machine-output switch for single-result commands:
  `spore --json <command> ...`.
- Keep success schemas command-owned and typed in Zig.
- Use one shared JSON error envelope for SporeVM-originated failures.
- Keep stream output explicit through a separate JSONL event mode for commands
  that need lifecycle events.
- Factor command implementations through product APIs before adding any public C
  ABI.
- Make a future `libspore` transport a wrapper over the same product API and
  JSON contracts, not a second behavior surface.
- Keep docs and field names generic: callers, automation, embedding, host,
  bundle, cache, run, resume, and materialization.
- Normalize existing JSON-default single-result commands so human summaries are
  the default and machine callers opt into JSON explicitly.

## Non-Goals

- No frozen Zig binary ABI or raw Zig struct layout exposed as an embedding
  contract.
- No compatibility promise before 1.0 beyond the current plan status.
- No preservation of current JSON-default or command-local `--json` behavior.
- No caller-specific execution policy, queue model, or deployment model in this
  repository.
- No formal JSON Schema files in the first slice unless they are generated from
  or tested against the Zig-owned contracts.
- No conversion of guest stdout/stderr into JSON for normal `spore run`.

## Target Model

There are three public output modes:

```console
spore host-info
spore inspect <spore-dir>
spore create <name> [options]
spore suspend <name> --out <spore-dir>
spore resume <spore-dir> --name <name>
spore rm <name>
spore inspect-bundle <bundle-ref> [--child ID|--child-range START..END]
spore pull <bundle-ref> --child ID --out <spore-dir>
```

Without a machine-output switch, single-result commands emit human-readable
summaries. The human text is intentionally not a stability boundary.

For one-document machine output:

```console
spore --json host-info
spore --json inspect <spore-dir>
spore --json create <name> [options]
spore --json suspend <name> --out <spore-dir>
spore --json resume <spore-dir> --name <name>
spore --json ls
spore --json rm <name>
spore --json inspect-bundle <bundle-ref> [--child ID|--child-range START..END]
spore --json pull <bundle-ref> --child ID --out <spore-dir>
```

These commands emit one JSON document on stdout on success. In global `--json`
mode, every SporeVM-originated failure that reaches argument parsing or command
execution emits exactly one JSON error object on stderr, emits nothing on stdout,
and exits with `error.exit_code`. Unsupported command-local `--json` spellings
are usage errors; they are not alternative machine-output modes.

Runtime streams stay separate:

```console
spore run --events=jsonl -- /bin/true
spore resume --events=jsonl <spore-dir>
```

`--events=jsonl` emits newline-delimited lifecycle events on stdout. It is not a
synonym for `--json`; it is the stream transport for commands whose useful
output is a sequence of states. In event mode, stdout is JSONL only. Guest
stdout and stderr are represented as typed events instead of raw byte streams.
The stream ends with exactly one terminal event. SporeVM-originated terminal
failures carry the same error object used by `spore --json` so callers do not
learn two failure taxonomies. The process exit status is the guest exit status
for guest completion and `error.exit_code` for SporeVM failures.

The internal shape should be:

```text
CLI parse
  -> product API call
    -> typed result or typed error
      -> CLI JSON/text/event serializer
      -> later C ABI JSON/callback serializer
```

The C ABI, if added, should be deliberately narrow and allocation-safe:

```c
typedef struct spore_inspect_bundle_options {
    uint32_t size;
    uint32_t version;
    /* versioned fields follow */
} spore_inspect_bundle_options_t;

spore_result_t spore_host_info_json(spore_context_t *, char **out_json);
spore_result_t spore_inspect_bundle_json(spore_context_t *, const spore_inspect_bundle_options_t *, char **out_json);
spore_result_t spore_pull_json(spore_context_t *, const spore_pull_options_t *, char **out_json);
spore_result_t spore_resume_events(spore_context_t *, const spore_resume_options_t *, spore_event_callback_t, void *);
void spore_free_string(spore_context_t *, char *);
```

The ABI returns JSON strings or calls event callbacks. It does not expose Zig
allocators, slices, error sets, or struct layout. Every public C options struct
must start with `size` and `version`, and ABI entrypoints must fail closed on
unknown incompatible versions.

## Contract Ownership

Canonical schema ownership stays in code:

- `src/machine_output.zig` should own shared schema constants, error envelope
  structs, digest references, cache-state names, rootfs references, and common
  event/result helpers.
- `src/platform.zig` should own the `spore.host-info.v1` result.
- `src/bundle.zig` should own bundle inspection and pull result structs.
- run/resume event structs should live with the run/resume lifecycle code, while
  reusing the shared error envelope.
- `src/main.zig` should only parse CLI arguments and serialize the typed result
  or typed error.

Durable docs should explain the contract without duplicating every field as the
source of truth. A later `schemas/` directory is useful only if external
validators need JSON Schema artifacts. If added, generated or test-verified
artifacts should use names like:

```text
schemas/spore.error.v1.schema.json
schemas/spore.host-info.v1.schema.json
schemas/spore.bundle.inspect.v1.schema.json
schemas/spore.pull.result.v1.schema.json
schemas/spore.run-events.v1.schema.json
```

## Error Model

All machine-mode SporeVM failures should use one envelope:

```json
{
  "schema": "spore.error.v1",
  "schema_version": 1,
  "error": {
    "code": "object.not_found",
    "message": "A required local or remote object is missing.",
    "retryable": false,
    "scope": "object",
    "exit_code": 22,
    "source": "RootFSDigestCacheMiss"
  }
}
```

`source` is diagnostic. Callers key on `schema`, `schema_version`, and
`error.code`. `scope` should describe the SporeVM layer that failed, such as
`usage`, `host`, `platform`, `object`, `cache`, `manifest`, `guest`, or
`runtime`. Avoid fields that prescribe a particular caller action.

The first implementation should pin a small stable code table in tests:

| Code | Scope | Retryable | Meaning |
| --- | --- | --- | --- |
| `usage.invalid_argument` | `usage` | `false` | An argument was present but invalid. |
| `usage.missing_argument` | `usage` | `false` | A required argument was absent. |
| `host.unsupported` | `host` | `false` | The host lacks a required capability. |
| `host.unavailable` | `host` | `true` | A required host service or device is temporarily unavailable. |
| `object.not_found` | `object` | `false` | A required object reference could not be resolved. |
| `object.invalid` | `object` | `false` | A resolved object is malformed or fails validation. |
| `cache.unavailable` | `cache` | `true` | A required cache root cannot be reached or prepared. |
| `cache.integrity_failed` | `cache` | `false` | Cached bytes do not match the expected digest. |
| `runtime.start_failed` | `runtime` | `true` | Runtime setup failed before guest execution completed. |
| `runtime.execution_failed` | `runtime` | `false` | Guest execution reached a SporeVM-managed failure state. |

## Safety And Invariants

- JSON mode must never silently weaken verification. It only changes reporting.
- Single-result command defaults are human-readable; machine callers must use
  global `--json`.
- A success result means the command reached its documented completion point.
  For `pull`, that means bytes are verified and the selected spore directory has
  been written. For lifecycle `create`, it means the monitor is ready; for
  lifecycle `suspend`, it means the checkpoint directory has been written and
  runtime state has been removed; for lifecycle `resume`, it means the monitor
  is ready; for lifecycle `rm`, it means runtime state has been removed.
- Runtime guest stdout/stderr are workload streams, not structured SporeVM
  result documents, so `spore exec` is not a one-document JSON command.
- Event streams are line-delimited, stdout contains only event JSONL, and each
  line is a complete JSON object.
- Error codes are stable product values; internal Zig error names may change.
- Result schemas include `schema` and `schema_version`.
- Command-local `--json` flags are not public machine-output contracts.
- Public contracts must stay backend-neutral unless a field is explicitly a
  backend fact or capability.
- Library bindings must not depend on Zig ABI stability or caller-owned Zig
  allocators.

## Current Progress

- Slice 1 is implemented in this branch: global `--json` is parsed before
  command dispatch, supported machine-mode parser failures emit
  `spore.error.v1`, existing JSON-default single-result commands have human
  defaults, `ls` now uses a human table by default, and `system` and `ls` now
  use global JSON instead of command-local `--json`.
- Slice 2 is implemented in this branch: `host-info` now emits
  `spore.host-info.v1` under global `--json` and a human summary by default,
  with host class, platform facts, backend availability, and cache roots.
- Slice 3 is implemented in this branch: `inspect-bundle` exposes
  `spore.bundle.inspect.v1`, `pull` emits `spore.pull.result.v1` with shared
  digest, materialization, rootfs, remote, and child-selection summaries, and
  the smoke scripts consume the nested machine contract through global `--json`.
- Slice 4 is implemented in this branch: `run` and `resume` accept
  `--events=jsonl`, stdout is JSONL in event mode, guest stdout/stderr are
  base64-encoded typed events, vsock readiness emits `ready`, and runtime
  terminal failures emit `failure` records using the shared error
  classification. Older parser/setup
  direct exits remain a follow-up hardening item outside the runtime stream
  path.
- Slice 5 is implemented in this branch: `src/api.zig` exposes option-based
  product calls for run, managed fresh run setup, `run --from` semantics,
  resume, host-info, inspect, fork, pack, unpack, push, inspect-bundle, and
  pull; run/resume expose typed event callbacks instead of CLI JSONL writer
  plumbing; pull and bundle materialization use explicit `env`/`none`/`path`
  cache choices; most public calls take a small `libspore.Context`, while
  managed fresh runs take `std.process.Init` because image/rootfs and kernel
  setup can spawn tools, use process IO, and resolve process environment; and
  the CLI routes single-result host, manifest, fork, and bundle commands through
  the API boundary instead of using command parsing as the product interface.
  The public Zig module now exposes explicit deinit helpers for owned result
  fields and classified failure values for run/resume events instead of raw Zig
  error names.
- The build now publishes that shared Zig module as `libspore`. The in-repo CLI
  compiles through `spore_internal.api` because Zig requires a source file to
  belong to only one module in a compilation unit; external embedders should
  import `libspore`. Initrd assets, zmoltcp, and hypervisor linkage are module
  dependencies for VM execution but are not part of the public facade.

## Delivery Strategy

### Slice 1: Breaking Machine Output Normalization

Add `src/machine_output.zig` with shared schema names, the common error envelope,
JSON serialization helpers, and a global `--json` parser path in `src/main.zig`.

Parse global `--json` before command dispatch. Move argument, usage, and command
failure reporting for supported machine-output commands through the shared
envelope. Change existing JSON-default single-result commands to human defaults,
and remove or reject command-local `--json` spellings as usage errors.

Done when:

- global `--json` is parsed before command dispatch;
- supported `--json` success paths emit exactly one JSON document on stdout;
- supported `--json` failure paths, including parser failures, emit
  `spore.error.v1` on stderr and nothing on stdout;
- existing JSON-default single-result commands have human defaults;
- command-local `--json` paths are removed or rejected as usage errors;
- snapshot tests cover success and failure output;
- `mise run check` passes.

### Slice 2: Host Info Result Contract

Make `host-info` a product API returning a typed `spore.host-info.v1` result.
Support `spore --json host-info` for the machine contract and make plain
`spore host-info` emit a concise human summary.

Done when host facts include host class, backend availability, platform
compatibility facts, and cache roots without requiring callers to infer them
from local labels or environment conventions.

### Slice 3: Bundle Inspection And Pull Results

Add bundle inspection as a read-only product API that summarizes bundle metadata
without materializing a child. Rebase pull result changes onto the same shared
digest, rootfs, cache-state, and materialization structs.

Done when `spore --json inspect-bundle ...` and `spore --json pull ...` use
coherent schema names, cache-state values, and shared error handling.

### Slice 4: Run And Resume Events

Add `--events=jsonl` for run/resume lifecycle streams. Keep it separate from
`--json`. Reuse the shared error envelope inside failure events. In event mode,
guest stdout/stderr become typed events and stdout carries no raw guest bytes.

Done when start, ready, stdout, stderr, exit, and failure events are complete
JSONL records, there is exactly one terminal event, failure classification
matches `spore.error.v1`, and process exit behavior matches the target model.

### Slice 5: Product API Boundary

Move CLI command bodies behind a small product API layer in `src/api.zig`, where
this reduces duplication. The goal is not a broad framework; the goal is that
command parsing, product behavior, and serialization are separable.

Done when run, resume, host-info, inspect, fork, pack, unpack, push,
inspect-bundle, and pull can be called without constructing argv arrays, and
run/resume event consumers receive typed callbacks rather than CLI writer
plumbing.

### Slice 6: Optional C ABI

Add `src/c_api.zig` only after the internal API has held up through the CLI
slices. The first ABI should expose JSON strings and event callbacks, not raw
Zig data. All public C option structs must carry `size` and `version` fields,
and unsupported versions must return a structured error rather than attempting a
best-effort interpretation.

Done when a tiny C smoke can call host-info or inspect-bundle, free returned
strings correctly, and observe the same JSON contract as the CLI.

## Verification

- Unit tests for error classification and JSON envelope serialization.
- Parser tests for global `--json` position, command dispatch, and structured
  usage failures in machine mode.
- Golden JSON tests for host-info, bundle inspection, pull success, and error
  output.
- JSONL tests that parse each emitted run/resume event line independently.
- Snapshot tests for human defaults on commands that previously emitted JSON by
  default.
- Existing bundle, rootfs, run, resume, and smoke tests continue to pass.
- `mise run check` remains the default local gate.

If formal JSON Schema files are added later, CI should validate sample outputs
against them and verify that the schemas match the Zig-owned result structs.

## Key Learnings From Pressure-Testing

- A broad `--machine-readable` flag would hide whether a command emits one JSON
  document or a stream. The plan keeps `--json` and `--events=jsonl` separate.
- A library-first public ABI would force ABI and memory-ownership decisions too
  early. The plan factors code for embedding first, then adds a C ABI only if
  the product APIs settle.
- Duplicating schemas in docs or hand-written JSON Schema files would drift from
  the Zig implementation. The plan keeps Zig structs authoritative and treats
  external schema artifacts as generated or test-verified follow-up work.
- Error fields should describe SporeVM failure facts, not prescribe one caller's
  recovery workflow. The plan uses `scope`, `retryable`, and stable codes rather
  than action-specific language.
- Because the repository is pre-1.0, preserving existing JSON-default commands
  would keep the confused contract alive. The plan now treats the first slice as
  a breaking normalization.
- Parser errors are part of the machine contract. Leaving them as direct
  `exit(2)` paths would make the shared error envelope unreliable for callers.
- Runtime event mode needs stream ownership rules, not just event names. The plan
  now makes JSONL stdout the only event channel and represents guest output as
  events.
- Library result ownership needs to be explicit even before a C ABI exists.
  Arena allocation is fine for many Zig callers, but the public module should
  still name which result fields it owns and provide matching cleanup helpers.

## Resolved Decisions

- Global `--json` is the single-result machine-output switch.
- `--events=jsonl` is the lifecycle stream switch.
- Existing JSON-default single-result commands will gain human defaults, and
  machine callers must use global `--json`.
- Command-local `--json` flags are not part of the public machine interface.
- Machine-mode parser failures use the shared JSON error envelope.
- JSON result and error contracts are owned by typed Zig structs.
- Future library bindings should expose JSON strings and callbacks through a C
  ABI, not raw Zig structs. Public C options structs must be size- and
  version-tagged.
- Contract docs must remain integration-neutral.

## Open Questions

- Should formal JSON Schema artifacts be generated in the first implementation
  PR? Default: no; start with Zig-owned structs and golden JSON tests.
