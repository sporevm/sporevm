# Automation contract

The CLI's `--json` output is SporeVM's only programmatic interface. Human
output remains intentionally unstable.

## CLI surfaces

Put global `--json` before the command, as in `spore --json vm ls`. Help is
human output: `spore --json <command> --help` fails with
`usage.invalid_argument`. The internal `monitor` and `netd` commands refuse
`--json`.

### Results

Commands other than `run`, `checkpoint resume`, `checkpoint fanout` and `vm exec` print exactly one
JSON result on stdout. A failure prints one `spore.error.v1`
document on stderr and nothing on stdout. Each result has `schema`,
`schema_version` and these top-level fields:

| Schema | Commands | Fields |
| --- | --- | --- |
| `spore.build.result.v1` | `build` | `resolved_image_ref`: string, `index_digest`: string, `metadata_path`: string, `local_ref_path`: string, `cache_hit`: boolean |
| `spore.lifecycle.v1` | `vm create`, `vm logs`, `vm save`, `vm restore`, `vm rm` | `resource_type`: string, `action`: string, `name`: string, `state`: string, `pid`: integer or null, `console_log_path`: string or null, `spore_dir`: string or null, `saved_sessions`: integer or null, `ownership`: string or null, `timing`: object or null, `initial_command`: object or null |
| `spore.copy.result.v1` | `vm copy-in`, `vm copy-out` | `direction`: string, `name`: string, `host_path`: string, `guest_path`: string |
| `spore.lifecycle.fork.result.v1` | `vm fork` | `resource_type`: string, `source`: string, `count`: integer, `children`: array of strings, `ram_capture_ms`: integer or null, `disk_fork_ms`: integer or null, `source_pause_ms`: integer or null, `child_ready_ms`: integer or null |
| `spore.lifecycle.list.result.v2` | `vm ls` | `entries`: array of objects |
| `spore.inspect.result.v1` | `checkpoint inspect` | `resource_type`: string, `portability`: string, `can_attach`: boolean, `can_run_from`: boolean, `version`: integer, `vm_state_present`: boolean, `storage_mode`: string, `ownership`: string, `vcpu_count`: integer, `platform`: object, `device_count`: integer, `memory_chunk_count`: integer, `present_memory_chunk_count`: integer, `memory_backing_kind`: string or null, `memory_backing_size`: integer or null, `initial_memory_bytes`: integer, `max_memory_bytes`: integer, `requested_memory_bytes`: integer, `captured_memory_bytes`: integer, `plugged_memory_ranges`: array of objects, `gic_kind`: string, `sessions`: array of objects, `network`: object or null, `annotations`: object, `annotation_keys`: array of strings |
| `spore.fork.result.v1` | `checkpoint fork` | `resource_type`: string, `parent`: string, `out_dir`: string, `count`: integer, `parent_generation`: integer, `first_generation`: integer, `last_generation`: integer, `first_child`: string, `last_child`: string, `pin_publish_ms`: integer or null, `pin_lock_wait_ms`: integer or null |
| `spore.saved.remove.result.v2` | `checkpoint rm` | `resource_type`: string, `action`: string, `spore_dir`: string |
| `spore.push.result.v2` | `checkpoint push` | `resource_type`: string, `ref`: string, `digest_ref`: string, `tag_ref`: string or null, `spore_digest`: string, `objects_total`: integer, `objects_written`: integer, `bytes_written`: integer |
| `spore.pull.result.v2` | `checkpoint pull` | `resource_type`: string, `ref`: string, `spore_digest`: string, `out_dir`: string, `ram`: object, `disk`: object |
| `spore.rootfs.import.result.v2` | `image import-oci`, `image import-tar` | `metadata_path`: string, `local_ref_path`: string, `resolved_image_ref`: string, `image_manifest_digest`: string, `rootfs_storage`: object |
| `spore.rootfs.resolve.result.v1` | `image resolve` | `ref`: string, `resolved_image_ref`: string, `platform`: object |
| `spore.rootfs.build.result.v1` | `image export-rootfs` | `rootfs_storage`: object |
| `spore.image.push.result.v1` | `image push` | `resource_type`: string, `ref`: string, `digest_ref`: string, `tag_ref`: string or null, `platform`: object, `image_digest`: string, `objects_total`: integer, `objects_written`: integer, `bytes_written`: integer |
| `spore.image.archive.pack.result.v1` | `image pack` | `resource_type`: string, `archive_digest`: string, `manifest_digest`: string, `image_digest`: string, `object_count`: integer, `archive_bytes`: integer, `platform`: object |
| `spore.image.archive.unpack.result.v1` | `image unpack` | `resource_type`: string, `resolved_image_ref`: string, `manifest_digest`: string, `image_digest`: string, `object_count`: integer, `platform`: object |
| `spore.host-info.v3` | `system info` | `host_class`: string, `architecture`: string, `platform`: object, `backends`: array of objects, `cache_roots`: object |
| `spore.system.df.result.v1` | `system df` | `cache_root`: string, `image_rootfs`: object, `linked_image_rootfs`: object, `image_metadata`: object, `digest_artifacts`: object, `cas_indexes`: object, `cas_objects`: object, `cas_complete_stamps`: object, `ref_records`: object, `temp_entries`: object, `build_cache_mounts`: object, `known_logical_bytes`: integer, `default_prunable_bytes`: integer |
| `spore.system.prune.result.v1` | `system prune` | `cache_root`: string, `dry_run`: boolean, `include_digest_artifacts`: boolean, `include_rootfs_chunks`: boolean, `older_than_seconds`: integer or null, `max_bytes`: integer or null, `scope_bytes_before`: integer, `scope_bytes_after`: integer, `candidate_count`: integer, `candidate_bytes`: integer, `candidate_reclaimable_bytes`: integer, `cache_mount_candidate_count`: integer, `cache_mount_candidate_reclaimable_bytes`: integer, `default_selection`: boolean, `deleted_count`: integer, `deleted_bytes`: integer, `deleted_reclaimable_bytes`: integer, `cache_mount_deleted_count`: integer, `cache_mount_deleted_reclaimable_bytes`: integer, `entries`: array of objects, `runtime_forks`: object or null |
| `spore.cache.gc.result.v2` | `system gc` | `cache_root`: string, `dry_run`: boolean, `rooted_indexes`: integer, `rooted_objects`: integer, `unparseable_metadata_count`: integer, `unparseable_step_record_count`: integer, `unparseable_pin_count`: integer, `pin_index_validation_count`: integer, `stale_step_record_count`: integer, `step_record_candidate_count`: integer, `step_record_deleted_count`: integer, `candidate_count`: integer, `candidate_bytes`: integer, `deleted_count`: integer, `deleted_bytes`: integer, `cache_mount_candidate_count`: integer, `cache_mount_candidate_bytes`: integer, `cache_mount_deleted_count`: integer, `cache_mount_deleted_bytes`: integer, `entries`: array of objects |
| `spore.cache.pins.result.v1` | `system pins` | `entries`: array of objects |
| `spore.cache.unpin.result.v1` | `system unpin` | `action`: string, `id`: string |
| `spore.version.result.v1` | `version` | `version`: string, `build_mode`: string |

- `resource_type` is `live_vm`, `checkpoint` or `image`.
- `initial_command`, from `vm create` and `vm logs`, reports the output
  disposition, destination, bound and startup status; `vm logs` adds the
  process status, exit code, retained output and per-stream truncation flags.
- Each `vm ls` entry's `memory` is an object with `initial_bytes` and
  `maximum_bytes`, or null when the VM's spec cannot be read.
- A fixed-memory checkpoint reports one value for all four memory sizes and an
  empty `plugged_memory_ranges`.
- `build` suppresses executor output, so its result is the only stdout.

### Event streams

`run`, `checkpoint resume`, `checkpoint fanout` and `vm exec` print `spore.automation.event.v1`
records on stdout, one per line, instead of the guest's raw output. Every
stream, including one that fails on its arguments, ends with exactly one
`completion` record:

```json
{"schema":"spore.automation.event.v1","schema_version":1,"event":"completion","outcome":"completed","command":"exec","backend":null,"exit_code":0}
```

Wire identifiers do not change with CLI spelling: `checkpoint resume` reports
`command: "attach"`, `checkpoint fanout` reports `"fanout"`, and `vm exec`
reports `"exec"`. Historical schema and capability names such as `can_attach`
also remain unchanged. Push results add `digest_ref` and nullable `tag_ref`;
use `digest_ref` for immutable automation inputs. The legacy `ref` is still
the publication ref for image push and the digest ref for checkpoint push.

`outcome` is `completed`, `failed`, or `canceled`. `completed` means SporeVM
delivered the operation's terminal result; a guest process can therefore be
completed with a non-zero `exit_code`. Failed and canceled completions contain
the same `error` body as `spore.error.v1`, and their top-level `exit_code`
matches the stable classified status in that body. Run and attach completions
report `memory_bytes`, the initial guest-visible memory, and
`max_memory_bytes`, the ceiling; equal values mean fixed memory.

An event consumer must treat EOF, a broken pipe, or a transport error before
`completion` as `stream.interrupted`. It must not infer success from a final
stdout/stderr record. Re-running after interruption is caller-dependent because
the underlying operation may have completed after the consumer lost the stream.

Fanout output events add a `child` field so callers can separate each child's
stdout and stderr without parsing human prefixes. They also carry a byte
`offset` and `byte_count` within that child's stream. Fanout emits one
`child_completion` for every child; a non-zero guest exit is a completed child
result and contributes that status to the aggregate completion, while an
abnormal child termination fails the aggregate stream.

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

## Compatibility

Schema names include their major version and every document also includes
`schema_version`. Additive fields may appear within a major version. Removing or
renaming a field, changing its type, changing terminal detection, or changing a
stable code's meaning requires a new schema major version. Consumers should
ignore unknown fields and reject unsupported schema names or major versions.
