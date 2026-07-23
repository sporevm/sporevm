# Automation contract

SporeVM has one versioning and terminal-outcome contract across the CLI, Zig
API, C ABI, and Go binding. Human output remains intentionally unstable.

## CLI surfaces

Bounded commands use global `spore --json <command> ...` and emit exactly one
schema-versioned JSON result on stdout. SporeVM failures emit one
`spore.error.v1` document on stderr and nothing on stdout. The bounded surface
includes version and inspection, system and cache operations, rootfs and image
operations, build, named lifecycle and copy operations, and bundle distribution
operations.

Runtime streams use command-local `--events=jsonl`. `run`, `attach`, `restore`,
`exec`, and `fanout` emit `spore.automation.event.v1` records. Each completed stream ends
with exactly one `completion` record:

```json
{"schema":"spore.automation.event.v1","schema_version":1,"event":"completion","outcome":"completed","command":"exec","backend":null,"exit_code":0}
```

`outcome` is `completed`, `failed`, or `canceled`. `completed` means SporeVM
delivered the operation's terminal result; a guest process can therefore be
completed with a non-zero `exit_code`. Failed and canceled completions contain
the same `error` body as `spore.error.v1`.

An event consumer must treat EOF, a broken pipe, or a transport error before
`completion` as `stream.interrupted`. It must not infer success from a final
stdout/stderr record. Re-running after interruption is caller-dependent because
the underlying operation may have completed after the consumer lost the stream.

`monitor` and `netd` are internal helper roles, not public automation commands.
Normal `run`, `attach`, `exec`, and `fanout` output remains raw unless
`--events=jsonl` is selected. Fanout output events add a `child` field so
callers can separate each child's stdout and stderr without parsing human
prefixes. Build is bounded in global JSON mode: executor output is suppressed
and the final `spore.build.result.v1` document is the only stdout value.

The bounded schema inventory is:

| Operations | Result schemas |
| --- | --- |
| `version`, `host-info`, `inspect` | `spore.version.result.v1`, `spore.host-info.v2` or `.v3`, `spore.inspect.result.v1` |
| artifact `fork`, `pack`, `unpack`, `push`, `inspect-bundle`, `pull` | `spore.fork.result.v1`, `spore.pack.result.v1`, `spore.unpack.result.v1`, `spore.push.result.v1`, `spore.bundle.inspect.v1`, `spore.pull.result.v1` |
| `create`, `save`, `restore`, named `rm`, named `fork`, `ls`/`ps`, `copy-in`/`copy-out` | `spore.lifecycle.v1`, `spore.saved.remove.result.v1`, `spore.lifecycle.fork.result.v1`, `spore.lifecycle.list.result.v1`, `spore.copy.result.v1` |
| `build`, rootfs operations, image gateway operations | `spore.build.result.v1`, `spore.rootfs.build.result.v1`, `spore.rootfs.import.result.v1`, `spore.rootfs.resolve.result.v1`, `spore.rootfs.cas-preload.result.v1`, `spore.image.pull.result.v1`, `spore.image.fixture.result.v1` |
| `system df`/`prune`, `cache gc`/`pins`/`unpin` | `spore.system.df.result.v1`, `spore.system.prune.result.v1`, `spore.cache.gc.result.v1`, `spore.cache.pins.result.v1`, `spore.cache.unpin.result.v1` |

Zig run and attach results use `spore.run.result.v1`. The bounded named-exec
compatibility collector used by Zig, C, and Go uses `spore.exec.result.v1`;
streaming callers should use the completion contract instead.

## Stable failures

Failures have a stable code, scope, and retry classification:

```json
{
  "schema": "spore.error.v1",
  "schema_version": 1,
  "error": {
    "code": "object.not_found",
    "message": "A required object reference could not be resolved.",
    "retry": "after_fix",
    "retryable": false,
    "scope": "object",
    "exit_code": 22,
    "source": "NamedVmNotFound"
  }
}
```

Callers branch on `code`, `scope`, and `retry`; `message` and `source` are
diagnostic. `retry` is `after_fix` when the same request needs repaired input or
configuration, `transient` when an unchanged request may succeed later, and
`unknown` when SporeVM cannot promise that retry is safe. `retryable` remains a
boolean projection and is true only for `transient`.

The stable v1 codes are:

| Code | Scope | Retry |
| --- | --- | --- |
| `usage.invalid_argument` | `usage` | `after_fix` |
| `usage.missing_argument` | `usage` | `after_fix` |
| `host.unsupported` | `host` | `after_fix` |
| `host.unavailable` | `host` | `transient` |
| `object.not_found` | `object` | `after_fix` |
| `object.invalid` | `object` | `after_fix` |
| `cache.unavailable` | `cache` | `transient` |
| `cache.integrity_failed` | `cache` | `after_fix` |
| `runtime.start_failed` | `runtime` | `transient` |
| `runtime.execution_failed` | `runtime` | `unknown` |
| `operation.canceled` | `operation` | `unknown` |
| `stream.interrupted` | `stream` | `unknown` |

## Library alignment

Zig exposes `ClassifiedFailure`, `TerminalOutcome`, and typed run events. C ABI
failures retain the existing result code and expose the matching borrowed
`spore.error.v1` document through `spore_context_last_error_json`. Go decodes
that document into `CallError` fields. Streaming named exec uses one completion
event with a terminal outcome in C and Go; a transport failure returned by
`Next` is classified as `stream.interrupted` instead of masquerading as a guest
result.

## Compatibility

Schema names include their major version and every document also includes
`schema_version`. Additive fields may appear within a major version. Removing or
renaming a field, changing its type, changing terminal detection, or changing a
stable code's meaning requires a new schema major version. Consumers should
ignore unknown fields and reject unsupported schema names or major versions.
