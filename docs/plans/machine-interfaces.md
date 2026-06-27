---
status: active
last_reviewed: 2026-06-27
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/distribution.md
  - docs/spore-format.md
  - docs/libspore.md
  - src/api.zig
  - src/libspore.zig
  - src/c_api.zig
  - src/main.zig
  - src/platform.zig
  - src/bundle.zig
  - src/run.zig
  - src/resume.zig
  - include/spore.h
related_plans:
  - docs/plans/foundation.md
  - docs/plans/run-bridge.md
  - docs/plans/distribution.md
---

# Machine Interfaces Plan

## Summary

SporeVM needs a stable machine interface that is useful from scripts, services,
tests, and embedded callers without making the CLI the only architecture
boundary. The process contract remains the widest compatibility surface:
commands accept normal arguments, single-result commands default to human
output, and `spore --json <command>` is the only one-document machine-output
mode.

The implementation should be factored around one product API: every `spore` CLI
command delegates product behavior to the same source used by `libspore`,
product APIs return typed result structs, and the CLI is one parser and
serializer over those structs. The source-level Zig module is published as
`libspore`; the C ABI wraps settled calls without exposing raw Zig structs; the
Go interface should be an idiomatic cgo adapter over that C ABI, not a second
runtime implementation or a CLI wrapper.

This plan deliberately keeps the contract SporeVM-native. The abstractions are
host facts, bundle inspection, materialization, run/resume lifecycle events,
cache roots, and classified failures. They should compose with any caller that
can execute a process, import the Zig module, embed the C ABI, or use a Go
binding, without naming a particular higher-level system in the product
contract.

## Problem

Several SporeVM commands already emit JSON, but the behavior is not one coherent
machine interface:

- some commands are always JSON;
- some commands have command-local `--json`;
- runtime output and result output are mixed differently by command;
- error classification is mostly internal Zig error names;
- typed result structs live with the implementation but are not clearly owned as
  product contracts;
- additional embedding surfaces would either duplicate CLI behavior or depend on
  command parsing details.

The repository is still pre-1.0, so this plan should use a breaking
normalization rather than preserve ad hoc output compatibility. Without a single
model, callers learn command-specific conventions and then carry those
conventions forever. That makes it harder to tighten error handling, add event
streams, or keep library transports aligned.

## Goals

- Define one global machine-output switch for single-result commands:
  `spore --json <command> ...`.
- Keep success schemas command-owned and typed in Zig.
- Use one shared JSON error envelope for SporeVM-originated failures.
- Keep stream output explicit through a separate JSONL event mode for commands
  that need lifecycle events.
- Keep all `spore` CLI product behavior behind `src/api.zig` and exported
  through `src/libspore.zig`, so the CLI, C ABI, and Go binding share behavior.
- Make C and Go library surfaces wrappers over the same product API and JSON
  contracts, not second behavior surfaces.
- Add Go methods only after the matching product call and C ABI endpoint exist.
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
- No Go-native reimplementation of VM execution, bundle handling, cache policy,
  or command parsing.
- No Go CLI fallback path in the binding; Go callers should fail clearly when
  the required `libspore` C ABI is unavailable.

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
spore resume --generation generation.json --events=jsonl <spore-dir>
```

`--events=jsonl` emits newline-delimited lifecycle and runtime audit events on
stdout. It is not a synonym for `--json`; it is the stream transport for
commands whose useful output is a sequence of states. In event mode, stdout is
JSONL only. Guest stdout and stderr are represented as typed events instead of
raw byte streams, and network audit records such as denied egress attempts use
typed events instead of debug log scraping. The stream ends with exactly one
terminal event. SporeVM-originated terminal failures carry the same error object
used by `spore --json` so callers do not learn two failure taxonomies. The
process exit status is the guest exit status for guest completion and
`error.exit_code` for SporeVM failures.
`resume --generation` is the single-child fan-out identity injection surface;
it reuses the generation attach path and still preserves the JSONL event stream.

The internal shape should be:

```text
CLI parse
  -> product API call
    -> typed result or typed error
      -> CLI JSON/text/event serializer

C ABI entrypoint
  -> product API call
    -> JSON string or event callback serializer

Go package
  -> C ABI entrypoint
    -> decoded Go struct or typed event callback
```

The CLI may own argv parsing, usage text, exit-status mapping, and output
serialization. It must not own runtime, bundle, manifest, cache, lifecycle,
network, or host-capability behavior. If a command needs product behavior that
is not present in `src/api.zig`, add the product operation first and make the
CLI call it.

The C ABI should stay deliberately narrow and allocation-safe:

```c
typedef struct SporeInspectBundleOptions {
    uint32_t size;
    uint32_t version;
    /* versioned fields follow */
} SporeInspectBundleOptions;

SporeResult spore_host_info_json(SporeContext context, SporeOwnedString *out_json);
SporeResult spore_inspect_bundle_json(SporeContext context,
                                      const SporeInspectBundleOptions *options,
                                      SporeOwnedString *out_json);
SporeResult spore_pull_json(SporeContext context,
                            const SporePullOptions *options,
                            SporeOwnedString *out_json);
SporeResult spore_resume_events(SporeContext context,
                                const SporeResumeOptions *options,
                                SporeEventCallback callback,
                                void *callback_context);
void spore_free_string(SporeContext context, SporeOwnedString string);
```

The shipped header currently exposes build info, context management, environment
overrides, host-info JSON, network capabilities JSON, inspect-bundle JSON, named
lifecycle JSON, context-local errors, and owned-string cleanup. Pull and resume
show the next-operation shape, not a separate ABI style. The ABI returns JSON
strings or calls event callbacks. It does not expose Zig allocators, slices,
error sets, or struct layout. Every public C options struct must start with
`size` and `version`, and ABI entrypoints must fail closed on unknown
incompatible versions.

The Go package should live in `bindings/go` until packaging pressure justifies a
separate repository. Its public surface should decode the same JSON contracts
into Go structs and adapt C event callbacks into Go callbacks:

```go
client, err := spore.New()
defer client.Close()

info, err := client.HostInfo(ctx)

bundle, err := client.InspectBundle(ctx, spore.InspectBundleOptions{
    Source: "file:///tmp/base.bundle",
})
```

Go `context.Context` support should be honest. Short metadata calls can check
context before entering C. Long-running run/resume cancellation should not be
promised until the Zig product API and C ABI expose a cancellation primitive.

New public operations should graduate in this order:

1. Zig product API in `src/api.zig` and exported through `src/libspore.zig`.
2. CLI serializer or event stream when the operation has a CLI command.
3. C ABI wrapper with size/version options, owned-string cleanup, and a C smoke.
4. Go wrapper over the C ABI with decoded structs and a Go test.

## Contract Ownership

Canonical schema ownership stays in code:

- `src/api.zig` should own product operation options, result ownership rules,
  and the backend-neutral shape consumed by all adapters.
- `src/libspore.zig` should re-export only the product-facing Zig surface.
- `src/machine_output.zig` should own shared schema constants, error envelope
  structs, digest references, cache-state names, rootfs references, and common
  event/result helpers.
- `src/platform.zig` should own the `spore.host-info.v1` result.
- `src/bundle.zig` should own bundle inspection and pull result structs.
- run/resume event structs should live with the run/resume lifecycle code, while
  reusing the shared error envelope.
- `src/c_api.zig` should translate settled product calls into C-owned JSON
  strings, error codes, context-local last errors, and callbacks.
- `bindings/go` should translate C ABI calls into idiomatic Go structs and
  callbacks without adding behavior that is not present in `libspore`.
- `src/main.zig` should only parse CLI arguments and serialize the typed result
  or typed error. It may import the internal module root for Zig build-system
  reasons, but CLI command bodies should call the product API rather than
  backend, storage, manifest, or lifecycle internals directly.

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
- Each `spore` CLI command must route product behavior through the same API
  surface exported by `libspore`; direct calls into lower-level internals are
  acceptable only when implementing that product API, not when handling CLI
  commands.
- Each C or Go entrypoint must map to one product operation. If a binding needs
  behavior not present in `src/api.zig`, add the product operation first.
- Go bindings must not shell out to `spore`; process-based callers already have
  the CLI contract.

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
  base64-encoded typed events, network denied-egress audit records emit
  `network` events, vsock readiness emits `ready`, and runtime terminal
  failures emit `failure` records using the shared error classification. Older
  parser/setup direct exits remain a follow-up hardening item outside the
  runtime stream path.
- Slice 5 is active in this branch: `src/api.zig` exposes option-based
  product calls for run, managed fresh run setup, `run --from` semantics,
  resume, host-info, inspect, fork, pack, unpack, push, inspect-bundle, and
  pull; run/resume expose typed event callbacks instead of CLI JSONL writer
  plumbing; pull and bundle materialization use explicit `env`/`none`/`path`
  cache choices; most public calls take a small `libspore.Context`, while
  managed fresh runs take `std.process.Init` because image/rootfs and kernel
  setup can spawn tools, use process IO, and resolve process environment; and
  the CLI has begun routing single-result host, manifest, fork, bundle, and
  named `create`/`resume`/`fork`/`exec`/`rm`/`suspend`/`ls` commands through
  the API boundary instead of using command parsing as the product interface.
  `system df` and `system prune` now share typed rootfs cache summary and prune
  operations with `libspore`, with dry-run/default-selection behavior owned by
  that API layer.
  Remaining CLI product paths should move behind the same boundary before the
  surface is considered complete.
  The public Zig module now exposes explicit deinit helpers for owned result
  fields and classified failure values for run/resume events instead of raw Zig
  error names.
- The build now publishes that shared Zig module as `libspore`. The in-repo CLI
  compiles through `spore_internal.api` because Zig requires a source file to
  belong to only one module in a compilation unit; external embedders should
  import `libspore`. Initrd assets, zmoltcp, and hypervisor linkage are module
  dependencies for VM execution but are not part of the public facade.
- Slice 6 is implemented on main: `include/spore.h` declares the first
  C ABI, `src/c_api.zig` wraps the product API behind opaque context and owned
  string helpers, the build installs shared/static `libspore` artifacts plus a
  pkg-config file, and C smoke coverage includes build info, option
  initialization, network capabilities, host-info JSON, inspect-bundle defaults,
  and named lifecycle defaults on aarch64 hosts.
- No Go binding exists yet. The intended first Go slice is a cgo wrapper over
  the existing C ABI for build info, host-info, and inspect-bundle only.

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
guest stdout/stderr become typed events, network audit records are typed events,
and stdout carries no raw guest bytes.

Done when start, ready, stdout, stderr, network, exit, and failure events are
complete JSONL records, there is exactly one terminal event, failure
classification matches `spore.error.v1`, and process exit behavior matches the
target model.

### Slice 5: Product API Boundary

Move all CLI product behavior behind a small product API layer in `src/api.zig`.
The goal is not a broad framework; the goal is that command parsing, product
behavior, and serialization are separable, and that the CLI does not become a
second source of truth beside `libspore`.

Done when every `spore` command that performs product work calls a product API
instead of lower-level implementation modules, run/resume/host-info/inspect/
fork/pack/unpack/push/inspect-bundle/pull can be called without constructing
argv arrays, and run/resume event consumers receive typed callbacks rather than
CLI writer plumbing.

### Slice 6: First C ABI

The first C ABI lives in `src/c_api.zig` and should only grow after the internal
API has held up through the CLI slices. The ABI should expose JSON strings and
event callbacks, not raw Zig data. All public C option structs must carry `size`
and `version` fields, and unsupported versions must return a structured error
rather than attempting a best-effort interpretation.

Done when a tiny C smoke can call host-info or inspect-bundle, free returned
strings correctly, and observe the same JSON contract as the CLI.

### Slice 7: First Go Binding

Add `bindings/go` as a cgo package over the existing C ABI. Keep the first
surface to build info, context lifetime, host-info, and inspect-bundle.

Done when Go tests can construct a client, call host-info and inspect-bundle
through `libspore`, decode the returned JSON into Go structs with schema fields,
free C-owned strings, and fail clearly when the library cannot be loaded or the
C ABI version is unsupported.

### Slice 8: Runtime Calls Through C And Go

Only after the first Go binding lands, add the next runtime-oriented C ABI
operation and Go wrapper. Prefer `pull`, `runFromSpore`, and `resumeSpore`
before exposing low-level `run`, because they are the product operations most
callers should use.

Done when the Zig API, CLI JSON or event stream, C ABI, and Go binding all
observe the same result schema, event ordering, terminal-event rule, error
classification, and ownership rules.

## Verification

- Unit tests for error classification and JSON envelope serialization.
- Parser tests for global `--json` position, command dispatch, and structured
  usage failures in machine mode.
- Golden JSON tests for host-info, bundle inspection, pull success, and error
  output.
- JSONL tests that parse each emitted run/resume event line independently.
- Snapshot tests for human defaults on commands that previously emitted JSON by
  default.
- C ABI smoke tests for every exported operation, including options
  initialization and owned-string cleanup.
- Go binding tests that decode the same JSON contracts rather than asserting a
  separate Go-only schema.
- Existing bundle, rootfs, run, resume, and smoke tests continue to pass.
- `mise run check` remains the default local gate.

If formal JSON Schema files are added later, CI should validate sample outputs
against them and verify that the schemas match the Zig-owned result structs.

## Key Learnings From Pressure-Testing

- A broad `--machine-readable` flag would hide whether a command emits one JSON
  document or a stream. The plan keeps `--json` and `--events=jsonl` separate.
- A library-first public ABI would have forced ABI and memory-ownership
  decisions too early. The plan factors code for embedding first, and future C
  ABI expansion plus Go binding work still follows settled product APIs.
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
- The Go API should not get ahead of the C ABI. Letting Go shell out to the CLI
  would be quick, but it would create a fourth behavior surface instead of
  testing the embedding contract.
- Allowing new CLI commands to call internals directly is the easiest way to
  drift. The plan treats CLI direct-to-internals code as transitional debt: add
  or deepen the product API first, then parse argv into that API.

## Resolved Decisions

- Global `--json` is the single-result machine-output switch.
- `--events=jsonl` is the lifecycle stream switch.
- Existing JSON-default single-result commands will gain human defaults, and
  machine callers must use global `--json`.
- Command-local `--json` flags are not part of the public machine interface.
- Machine-mode parser failures use the shared JSON error envelope.
- JSON result and error contracts are owned by typed Zig structs.
- All `spore` CLI product behavior delegates to the `libspore` product source
  of truth. The CLI owns parsing and serialization, not VM, bundle, manifest,
  cache, lifecycle, host-capability, or network behavior.
- Library bindings expose JSON strings and callbacks through a C ABI, not raw
  Zig structs. Public C options structs must be size- and version-tagged.
- The Go binding starts in `bindings/go`, uses cgo over the C ABI, and decodes
  the same JSON contracts into Go structs.
- Go methods are added only after the matching Zig product API and C ABI
  endpoint exist.
- Contract docs must remain integration-neutral.

## Open Questions

- Should formal JSON Schema artifacts be generated in the first implementation
  PR? Default: no; start with Zig-owned structs and golden JSON tests.
