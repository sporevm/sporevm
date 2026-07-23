# libspore

`libspore` is the Zig product API shared by `spore` and embedders. It exposes
typed operations and result contracts without making callers construct CLI
argument arrays.

The public module is [`src/libspore.zig`](../src/libspore.zig). It re-exports
the product surface from [`src/api.zig`](../src/api.zig); backend, device,
storage, monitor, and CLI modules stay internal.

## Product Contract

The CLI is the widest process contract: human output by default, global
`spore --json <command>` for supported single-result commands, and explicit
JSONL event streams for runtime events. Workload stdout and stderr stay workload
streams.

`libspore` is the in-process contract. The CLI, C ABI, and Go binding wrap the
same product APIs and JSON result schemas; they should not reimplement command
behavior or depend on CLI parsing.

`libspore.Architecture` and `RootfsPlatform.arch` use OCI names: `.arm64` and
`.amd64`. Backend spellings are intentionally absent from the product API.
`HostInfo` preserves the ARM-shaped `spore.host-info.v2` compatibility schema.
`HostInfoV3` uses an architecture-discriminated schema: its platform is
`arm64` on mature lifecycle hosts and `amd64` on experimental Linux/KVM
fresh-execution hosts. Serialized spore machine state retains `aarch64` and
`sporevm-aarch64-v0`; those are format and backend identifiers rather than
product platform values. AMD64 host-info support does not imply standalone
Zig, C, or Go execution support; those x86 execution paths remain gated while
the CLI alone exposes the experimental fresh profile.

The public vocabulary is `save`, `attach`, and `restore` across Zig, C, and Go.
JSONL run events keep their original `capture` event and `capture_path` fields
and add `ownership` on capture plus `capture_ownership` on terminal exit.
`ResourceType` distinguishes `.live_vm`, `.checkpoint`, `.image`, and
`.bundle`. Additive `resource_type` fields use the same values in JSON results.

## Importing

Add the module from this package in your `build.zig` dependency graph, then:

```zig
const libspore = @import("libspore");
```

Operations that need process context take `libspore.Context`:

```zig
const context = libspore.Context{
    .io = std.testing.io,
    .environ_map = &env,
};
```

`Context` carries IO and environment access. Managed fresh runs use
`std.process.Init` instead because they may spawn helper tools while resolving
images, rootfs inputs, and managed kernels.

## Ownership

Pass the same allocator to the operation and its matching deinit helper:

```zig
const info = try libspore.hostInfo(context, allocator);
defer libspore.deinitHostInfo(allocator, info);

const info_v3 = try libspore.hostInfoV3(context, allocator);
defer libspore.deinitHostInfoV3(allocator, info_v3);
```

Use the matching helper for owned results:

- `deinitHostInfo`
- `deinitHostInfoV3`
- `deinitSporeInspectResult`
- `deinitForkResult`
- `deinitPackResult`
- `deinitUnpackResult`
- `deinitPushResult`
- `deinitInspectBundleResult`
- `deinitPullResult`
- `deinitNamedLifecycleResult`
- `deinitExecNamedResult`
- `deinitNamedForkResult`
- `deinitNamedList`
- `deinitRootfsBuildResult`
- `deinitRootfsImportOciResult`
- `deinitRootfsImportTarResult`
- `deinitRootfsResolveResult`
- `deinitRootfsCasPreloadResult`
- `deinitRootfsSystemSummary`
- `deinitRootfsPruneResult`
- `deinitRemovedSavedSpore`

`run`, `runManaged`, `runFromSpore`, and `attachSpore` return value results and
do not need deinit.

Live VM lifecycle results and list entries use `resource_type: "live_vm"`.
Checkpoint inspection, fork, clone, unpack, pull, and removal use
`resource_type: "checkpoint"`, while bundle inspection, pack, and push use
`resource_type: "bundle"`. Images contain application filesystem and OCI
execution metadata; bundles and checkpoints contain no runnable image identity
of their own.

## Local Spore Inspection

Use `inspectSpore` to read metadata from a local `.spore` directory without
restoring or attaching to it, and without manually parsing `manifest.json`:

```zig
const inspected = try libspore.inspectSpore(allocator, "worker.spore");
defer libspore.deinitSporeInspectResult(allocator, inspected);

const workspace = inspected.annotations.map.get("cleanroom.workspace");
```

`inspectSpore` accepts every manifest format version that restore paths accept:
format v2 (single-vCPU) and format v3 (multi-vCPU) manifests both summarize,
and `SporeInspectResult.vcpu_count` reports the vCPU count (1 for v2).

`SporeInspectResult.vm_state_present` is the product-level VM-state signal for
callers that should not infer it from chunks, devices, or sessions. Valid local
spores report `true`. `SporeInspectResult.storage_mode` reports
`memory-only`, `exact-rootfs`, `chunked-rootfs`, or the same rootfs mode with
`-with-writable-disk`.

`resource_type` is `checkpoint`. `can_run_from` reports whether the checkpoint
can start a new process, while `can_attach` reports whether it records at least
one session that can be selected for attach. `portability` is `host_local`,
`portable`, or `batch_relative`; `ownership` retains the more specific
`machine-local-pinned`, `portable-self-contained`, or `batch-relative`
contract. Callers should use these fields instead of inferring operations or
copy safety from directory contents.

`SporeInspectResult.annotations` is an opaque key/value map copied out of the
validated manifest. SporeVM does not interpret namespaces such as
`cleanroom.*`; callers own their schema. The same manifest annotation rules
apply on read and write: keys and values must be UTF-8 strings, keys cannot be
empty, and the serialized annotation object is capped at 64 KiB.

`SporeInspectResult.sessions` exposes the manifest's generic session handles as
`Session` values with `SessionStreams` capabilities. These handles identify
reattachable guest process sessions only; host stdin, PTY ownership, terminal
mode, and currently attached clients are not serialized.

`SporeInspectResult.network` exposes the manifest network kind, capability
requirements, and bound-service requirements so callers can discover restore-time
bindings before calling `attachSpore` for saved-session attach or
`runFromSpore` for new commands.

## Local System

Use `systemDf` and `systemPrune` for rootfs cache inspection and cleanup without
constructing `spore system` argv:

```zig
const summary = try libspore.systemDf(context, allocator, .{
    .rootfs_cache = .env,
});
defer libspore.deinitRootfsSystemSummary(allocator, summary);

const pruned = try libspore.systemPrune(context, allocator, .{
    .rootfs_cache = .env,
    .dry_run = true,
    .older_than_seconds = 7 * 24 * 60 * 60,
});
defer libspore.deinitRootfsPruneResult(allocator, pruned);
```

`systemPrune` is dry-run by default. When no age or size limit is provided, it
selects the same default-prunable rootfs entries as `spore system prune`.
Digest/CAS artifacts require an explicit `older_than_seconds` or `max_bytes`
limit.

## Rootfs

Use rootfs APIs for the `spore rootfs` product operations without constructing
argv:

```zig
const built = try libspore.rootfsBuild(init, allocator, .{
    .ref = "docker.io/library/alpine:3.20",
    .output = "alpine.ext4",
    .metadata = "alpine.ext4.json",
});
defer libspore.deinitRootfsBuildResult(allocator, built);

const resolved = try libspore.rootfsResolve(init, allocator, .{
    .ref = "docker.io/library/alpine:3.20",
    .platform = .{ .arch = .amd64 },
});
defer libspore.deinitRootfsResolveResult(allocator, resolved);
```

`rootfsImportOci` imports OCI layouts under local refs, and `rootfsImportTar`
imports uncompressed rootfs tar files under the same local ref cache. Import
options default to `.rootfs_storage = .chunked`; flat-only imports are no
longer accepted because image-created spores use the rootfs storage index as
their portable identity.
`rootfsCasPreload` preloads a rootfs digest into chunked CAS storage and can
attach the resulting descriptor to an existing spore.

## Running

Use `runManaged` for the high-level `spore run` path:

```zig
const result = try libspore.runManaged(init, allocator, .{
    .image_ref = "docker.io/library/alpine:3.20",
    .guest_env = &.{"SPORE_TEST_ENV=ok"},
    .injected_files = &.{.{ .id = "config", .bytes = "{\"ok\":true}\n" }},
    .command = &.{ "/bin/true" },
});
```

For image-backed calls, an empty `.command` uses OCI Entrypoint plus Cmd. A
non-empty command replaces Cmd and follows Entrypoint. Set `.image_entrypoint`
to replace the image Entrypoint while retaining those Cmd rules. Image `User`
must select root until guest credential switching is supported. Non-image
managed runs still require a command, and saved-spore execution never applies
OCI command defaults.

Injected files are fresh-run only and appear under `/run/sporevm/injected`.
Spore rejects them with saved runs and `runFromSpore` so caller-provided bytes
do not accidentally become persisted spore state.

Set `.commit_ref = "local/name:tag"` on `ManagedRunOptions` to publish the
successful run's root disk as an image. This is available only on the managed
fresh-image path because it inherits the resolved source image config.
`RunResult.committed` reports whether publication happened; the synchronous
`.image_commit` event carries the mutable ref, resolved immutable image ref,
and rootfs index digest without returning allocator-owned strings from the
short-lived managed-run arena.
Set `.disk_size` to a 64 KiB-aligned absolute byte size when that commit needs a
larger root disk. Values below the source image size are rejected before boot;
guest filesystem-resize failure leaves the destination ref unchanged.

Use `runFromSpore` for `spore run --from` semantics:

```zig
const result = try libspore.runFromSpore(context, allocator, .{
    .spore_dir = "base.spore",
    .generation_path = "generation.json",
    .guest_env = &.{"SPORE_TEST_ENV=ok"},
    .command = &.{ "/bin/true" },
});
```

Set `.generation_path` when a fork or fleet adapter has run-specific fan-out
identity JSON to publish before the fresh command starts. Omitting it preserves
the saved spore's normal generation resume behavior.

`runFromSpore` requires a non-empty command and always creates a new process
session. Use the distinct `attachSpore` operation to select a recorded session:

```zig
const result = try libspore.attachSpore(context, allocator, .{
    .spore_dir = "base.spore",
    .session_id = "default",
    .interactive = true,
});
```

Set `.interactive = true` or `.tty = true` only when that saved session
supports stdin or a terminal. Unsupported input attach returns a usage error
before restore instead of silently downgrading to output-only attach.

`RunResult.memory_restore_source` and `memory_restore_reason` are populated for
`runFromSpore` and `attachSpore`, so embedders can tell whether RAM came from
`local_backing` or verified `chunks` without parsing logs.

Use `fork` to mint an offline child batch from a saved spore. For pinned
disk-backed parents, `ForkResult.pin_lock_wait_ms` reports time waiting for the
global cache lock and `pin_publish_ms` reports only the lock-held pin and batch
publication interval; both fields are null when durable pin publication is not
needed.

Use `removeSavedSpore` to remove a saved-spore directory and unregister its
durable disk pin when present. `RemovedSavedSpore.pin_removed` distinguishes
machine-local pinned removal from diskless or portable local-CAS removal;
`ownership` is `machine-local-pinned`, `portable-self-contained`, or
`batch-relative`, and `pin_id` is empty when no durable pin existed. New
machine-local pins refuse copied or duplicate ownership references, while
legacy shared pins refuse destructive removal. Use `cloneSpore` to make an
independently owned portable copy through the pack/unpack encoding. The owned `spore_dir` and
`pin_id` must be released with
`deinitRemovedSavedSpore`. Portable removal returns `SavedSporeInUse` while a
live restore still owns the directory as lazy disk authority.

Use `run` only when you already have explicit kernel and rootfs or disk inputs.

## Named Lifecycle

Use named lifecycle APIs when an embedder needs long-lived VM handles without
constructing `spore` command argv or touching the private monitor socket:

```zig
var create_annotations = libspore.Annotations{};
try create_annotations.map.put(allocator, "dev.buildkite.cleanroom.policy_hash", "sha256:abc123");
const created = try libspore.createNamed(init, allocator, .{
    .name = "worker-1",
    .image_ref = "docker.io/library/alpine:3.20",
    .annotations = create_annotations,
});
defer libspore.deinitNamedLifecycleResult(allocator, created);

const exec = try libspore.execNamed(context, allocator, .{
    .name = "worker-1",
    .command = &.{ "/bin/true" },
});
defer libspore.deinitExecNamedResult(allocator, exec);

try libspore.copyInNamed(context, allocator, .{
    .name = "worker-1",
    .host_path = "./local.txt",
    .guest_path = "/tmp/local.txt",
});
try libspore.copyOutNamed(context, allocator, .{
    .name = "worker-1",
    .guest_path = "/tmp/local.txt",
    .host_path = "./roundtrip.txt",
});

var save_annotations = libspore.Annotations{};
try save_annotations.map.put(allocator, "dev.buildkite.cleanroom.save", "warm");
const saved = try libspore.saveNamed(context, allocator, .{
    .name = "worker-1",
    .out_dir = "worker-1.spore",
    .annotations = save_annotations,
});
defer libspore.deinitNamedLifecycleResult(allocator, saved);

const restored = try libspore.restoreNamed(init, allocator, .{
    .spore_dir = "worker-1.spore",
    .name = "worker-2",
});
defer libspore.deinitNamedLifecycleResult(allocator, restored);

const forked = try libspore.forkNamed(init, allocator, .{
    .source_name = "worker-2",
    .count = 2,
    .name_pattern = "worker-child-%d",
});
defer libspore.deinitNamedForkResult(allocator, forked);
```

Image-backed `createNamed` starts the image's `Entrypoint` plus `Cmd` as its
initial process. Zig callers can set `.initial_command`, C callers can set
`initial_argv`, and Go callers can set `InitialArgv` to replace `Cmd` while
keeping `Entrypoint`. Non-image creates with no initial command remain idle.
The same root-only `User` restriction as `runManaged` applies. If the initial
process cannot be started, create removes the new named VM before returning an
error; a rollback failure is reported explicitly so the caller can remove it
by name. Once started, the process remains detached and its eventual exit does
not affect the create result. Initial stdout and stderr default to `.retain`,
which keeps 16,381 bytes per stream in the guest agent while continuously
draining excess output. Set `.initial_output = .discard` to restore the
discarding behavior. `initialOutputNamed` retrieves the bounded snapshot in the
same `spore.lifecycle.v1` `NamedLifecycleResult.initial_command` field used by
create, including destination, startup and process status, exit code, and
truncation flags. `removeNamed` destroys the VM and its retained bytes.

`forkNamed` supports diskless sources and the single writable rootfs disk used
by image-created, explicit-rootfs, restored, and previously forked named VMs.
Networked sources remain unsupported, and a batch is capped at 32 children.
Disk-backed fork requires native APFS/Linux cloning by default when physical
overrides remain; Zig callers can set `ForkNamedOptions.allow_slow_copy = true`
to permit a full dirty-overlay copy when native cloning is unavailable. After
a successful save commits the exact baseline, an override-free fork uses fresh
sparse heads and requires neither cloning nor slow-copy.

For disk-backed sources, `NamedForkResult` reports `ram_capture_ms`,
`disk_fork_ms`, `source_pause_ms`, and `child_ready_ms`. These phase metrics are
null for the existing diskless path. Success means every child has reopened its
baseline, consumed its one-use disk-head claim, and published monitor readiness.
The source can then be removed without invalidating child reads, nested forks,
or later saves.

For mutable image refs, Zig callers can set `.image_pull_policy` to `.missing`,
`.always`, or `.never`; the C and Go bindings use the default `.missing`
policy.

Named startup operations spawn a helper executable to run the private monitor
entry point. Zig and C callers default `spore_executable` to `"spore"`,
resolved with the process `PATH` used for the operation. Go callers default to
self re-exec through the linked embedder, described below.

Before `createNamed`, `restoreNamed`, or `forkNamed` returns success, the
monitor completes a dedicated guest-agent readiness request, then libspore
waits for `ready.json`, confirms the recorded PID is alive, connects to the
monitor's recorded internal control socket, and requires a `hello` response
carrying exactly the same version as `libspore.version`. Successful startup is
therefore exec-ready and does not require a caller-issued no-op command. Named lifecycle
JSON results include preparation, monitor-spawn, exec-ready wait, and total
timings in milliseconds.

Exact version equality is the compatibility rule. The monitor argv and control
socket protocol are private same-version contracts, not a stable cross-version
API. If libspore `1.5.0` resolves and starts a `spore` executable reporting
`1.3.0`, startup fails with a message naming both versions and the resolved
executable path.

The named surface is:

- `createNamed`
- `restoreNamed`
- `forkNamed`
- `execNamed`
- `initialOutputNamed`
- `openExecNamedStream`
- `copyInNamed`
- `copyOutNamed`
- `saveNamed`
- `removeNamed`
- `listNamed`

`saveNamed` saves while keeping the named VM running by default; set
`SaveNamedOptions.stop = true` to remove the live VM after saving. Use
`deinitNamedLifecycleResult`, `deinitExecNamedResult`,
`deinitNamedForkResult`, and `deinitNamedList` for owned results.
`copyInNamed` and `copyOutNamed` transfer explicit regular files or directory
trees and reject symlinks, special files, and overwrite. They do not perform
workspace sync.

Zig named lifecycle options still default `.spore_executable` to `"spore"`.
Set it to a matching helper executable unless the caller has installed its own
re-exec trampoline. The Go binding is the built-in trampoline today.

The Go binding installs the SporeVM re-exec trampoline during package init. If
`CreateNamedOptions.SporeExecutable` or `RestoreNamedOptions.SporeExecutable` is
empty, the binding passes the current executable path to libspore, so monitor
and `netd` child processes re-exec the same linked embedder instead of looking
up `spore` on `PATH`. Set `SporeExecutable` explicitly to keep using an
external helper during migration or debugging. When the resolved executable is
the current process, the pre-spawn `spore version` probe is skipped: self-exec
cannot skew, and probing an embedder binary would invoke the embedder's own
CLI.

On macOS, standalone Go embedders that use HVF must sign the final executable
with `com.apple.security.hypervisor`. Signing only `libspore.dylib` is not
enough because the monitor role is the embedder process.

Named lifecycle errors carry diagnostics in addition to the error tag. Zig
callers can read `lastLifecycleErrorMessage()` after a failed lifecycle call.
The C ABI copies the same text into `spore_context_last_error` and exposes its
stable `spore.error.v1` classification through
`spore_context_last_error_json`. The Go binding decodes both into `CallError`,
including `FailureCode`, `Scope`, `Retry`, and `Retryable`. Startup, already-exists, and not-ready
diagnostics include the last known VM state, recorded PID when present,
the configured console path when present, `monitor.log`, and the control socket
path where useful. When no console log is configured, diagnostics report
`console_log=none` instead of claiming a default file exists.

`openExecNamedStream` is the primary named-exec primitive and is also what the
CLI uses for plain noninteractive exec. It preserves stdout and stderr as
separate ordered streams, with stdin closed unless `.interactive = true`.
`execNamed` remains a compatibility collector for small commands: stdout and
stderr are each bounded to 16 KiB, and exceeding either bound returns
`error.ExecOutputTruncated` instead of a partial successful result. Interactive
or TTY collector requests return `error.UnsupportedInteractiveExec`.

The C JSON result keeps valid UTF-8 `stdout` and `stderr` as strings for
existing consumers. If either stream contains invalid UTF-8, that field is an
array of byte values from 0 through 255 instead, preserving the exact output.
The Go binding accepts both forms and returns the original bytes in its string
fields. Zig callers already receive owned byte slices. This hybrid encoding is
limited to the bounded compatibility collector; streaming events always carry
raw bytes.

Use the stream for output beyond the collector bound and interactive or TTY
exec:

```zig
var stream = try libspore.openExecNamedStream(context, allocator, .{
    .name = "worker-1",
    .command = &.{ "/bin/sh" },
    .interactive = true,
    .tty = true,
    .terminal_size = .{ .rows = 40, .cols = 120 },
});
defer stream.deinit();

try stream.writeTerminal("echo hi\n");
try stream.resizeTerminal(.{ .rows = 50, .cols = 100 });
while (true) {
    switch (try stream.next()) {
        .terminal => |bytes| try handleTerminal(bytes),
        .exit => |code| return code,
        .err => |bytes| return handleMonitorError(bytes),
        else => {},
    }
}
```

Stream event byte slices are borrowed until the next stream operation. C and Go
surface event type `COMPLETION` with a completed, failed, or canceled outcome;
failed and canceled completions borrow a `spore.error.v1` document until the
next stream call. A transport error before completion is classified as
`stream.interrupted` through the context error rather than as a guest result.
After `.exit` is returned in Zig, `stream.timing` contains the optional
`NamedExecTiming` received immediately before it. The bounded Zig
`ExecNamedResult` carries the same value. Its phases split dispatch, guest
process start, guest execution, guest user/system CPU, output/result delivery,
teardown, and total monitor time; telemetry does not affect command success.

## Networking

See [SporeVM Networking](networking.md) for the CLI policy and manifest
contract.

Call `networkCapabilities()` before accepting user policy:

```zig
const caps = libspore.networkCapabilities();
if (!caps.supported or !caps.exact_host_port) return error.UnsupportedNetworkPolicy;
```

The first networking slice supports TCP IPv4, DNS A-record learning, exact
host-plus-port policy, default deny policy, bound Unix services, one create-time
host loopback port forward for named VMs, and named exec decision-event capture.
It does not support IPv6, UDP egress, wildcard hosts, CIDR in Cleanroom policy,
SNI/HTTP matching, or live per-exec policy updates.

Create a named VM with exact egress and a bound host service:

```zig
const policy = libspore.NetworkPolicy{
    .allow = &.{.{
        .host = "github.com",
        .ports = &.{443},
    }},
};

const service = libspore.BoundService{
    .name = "cleanroom-gateway",
    .guest_host = "gateway.cleanroom.internal",
    .guest_port = 8170,
    .target = .{ .unix = "/tmp/cleanroom-gateway.sock" },
};

const forward = libspore.PortForwardConfig{
    .host_port = 18080,
    .guest_port = 8080,
};

const created = try libspore.createNamed(init, allocator, .{
    .name = "cr-test",
    .image_ref = "docker.io/library/alpine:3.20",
    .network = .{
        .enabled = true,
        .policy = policy,
        .bound_services = &.{service},
        .port_forwards = &.{forward},
    },
});
defer libspore.deinitNamedLifecycleResult(allocator, created);
```

Port forwards are live monitor state. They are closed when the named VM exits
and are not recorded in saved spore manifests.

`execNamed(.{ .network_policy = ... })` is part of the API contract but returns
`error.UnsupportedNetworkPolicyUpdate` in this slice. Callers that need
stage-scoped networking should start the VM with a single all-stage policy, or
reject stage-scoped policy until `networkCapabilities().stage_policy_update`
is true.

`ExecNamedResult.network_events_jsonl` contains decoded JSONL network events
recorded during the exec window. Bound service declarations are recorded in
saved manifests as restore-time requirements without host socket paths. On
restore, callers provide fresh live bindings keyed by service name:

```zig
const restored = try libspore.restoreNamed(init, allocator, .{
    .spore_dir = "cr-test.spore",
    .name = "cr-test-restored",
    .bound_services = &.{.{
        .name = "cleanroom-gateway",
        .target = .{ .unix = "/tmp/fresh-cleanroom-gateway.sock" },
    }},
});
defer libspore.deinitNamedLifecycleResult(allocator, restored);
```

The manifest remains portable: it records the service name, guest host, and
guest port, while the restore option supplies only the current host socket path.
Restore fails closed if any declared service lacks a live binding, if a binding
does not match a declared service name, or if duplicate bindings are supplied.
The Zig `runFromSpore` and `attachSpore` options use the same `.bound_services`
restore field.

## Events

Run and attach calls accept a synchronous `EventSink`:

```zig
fn emit(ctx: ?*anyopaque, event: libspore.RunEvent) anyerror!void {
    _ = ctx;
    switch (event) {
        .stdout => |output| {
            // output.bytes is valid only for this callback.
            _ = output.bytes;
        },
        .terminal => |output| {
            // TTY mode merges stdout and stderr into one terminal stream.
            _ = output.bytes;
        },
        .port_forward => |forward| _ = forward.guest_port,
        .save => |saved| _ = saved.save_path,
        .image_commit => |committed| _ = committed.rootfs_index_digest,
        .exit => |exit| _ = exit.exit_code,
        else => {},
    }
}

const result = try libspore.runFromSpore(context, allocator, .{
    .spore_dir = "base.spore",
    .command = &.{ "/bin/true" },
    .events = .{ .emitFn = emit },
});
```

Event callbacks run synchronously. Output byte slices are callback-scoped; copy
them if they must outlive the callback. TTY output arrives as `.terminal`
events. Bound Unix services emit `.port_forward` setup events without durable
host socket paths, and successful saves emit `.save` before `.exit`.
Successful image commits emit `.image_commit` before `.exit`.
Every run emits at most one terminal typed event: `.exit` for guest completion
or `.failure` for a SporeVM failure. The shared JSONL adapter serializes either
as one `spore.automation.event.v1` `completion` record with a `completed`,
`failed`, or `canceled` outcome. See [Automation contract](automation.md).

## Bundles

Bundle APIs use typed result contracts shared with the CLI JSON output:

```zig
const inspected = try libspore.inspectBundle(allocator, .{
    .source = "file:///tmp/base.bundle",
});
defer libspore.deinitInspectBundleResult(allocator, inspected);

const pulled = try libspore.pull(context, allocator, .{
    .source = "file:///tmp/base.bundle",
    .out_dir = "base.spore",
    .rootfs_cache = .env,
    .bundle_cache = .env,
});
defer libspore.deinitPullResult(allocator, pulled);
```

## Generated API Docs

Run:

```console
mise run docs
```

The generated Zig API docs are installed under
`zig-out/share/doc/spore/libspore-zig`.

## C ABI

The C ABI is declared in [`include/spore.h`](../include/spore.h). The current
surface exposes context management, build info, context-local environment
overrides, context-local last errors, owned string cleanup, host-info JSON,
inspect-bundle JSON, inspect-spore JSON, pull JSON, named lifecycle JSON, and
named copy side-effect calls. ABI version 15 added saved-spore removal through
`spore_remove_saved_json`; ABI version 16 added the architecture-discriminated
`spore_host_info_json_v3` entry point; ABI version 17 added
`SporeCreateNamedOptions.initial_argv`; ABI version 18 added structured last
errors and terminal outcomes for streaming named exec; ABI version 19 adds
`SporeCreateNamedOptions.initial_output` and
`spore_initial_output_named_json`. Clients should compare the runtime
build-info ABI with `SPORE_ABI_VERSION` before calling a newly added symbol.

Release builds publish separate `libspore_Linux` and `libspore_Darwin`
archives so CLI-only installs do not carry development files. Each libspore
archive contains:

- `include/spore.h`
- `lib/libspore.a`
- the platform shared library under `lib/`
- `lib/pkgconfig/libspore.pc`
- this guide and the project license

Use the archive that matches the target platform:

```bash
asset=libspore_Darwin # or libspore_Linux
tar -xzf "$asset.tar.gz"
export PKG_CONFIG_PATH="$PWD/$asset/lib/pkgconfig"
cc my_program.c -o my_program $(pkg-config --cflags --libs libspore)
```

When running from an unpacked archive instead of a system install, point the
dynamic loader at the archive lib directory:

```bash
# Linux
LD_LIBRARY_PATH="$PWD/$asset/lib:${LD_LIBRARY_PATH:-}" ./my_program

# macOS
DYLD_LIBRARY_PATH="$PWD/$asset/lib:${DYLD_LIBRARY_PATH:-}" ./my_program
```

To build and install the same layout from source:

```bash
zig build -Dtarget=aarch64-macos.13.0 --release=safe --prefix /path/to/prefix
export PKG_CONFIG_PATH="/path/to/prefix/lib/pkgconfig"
```

On Linux ARM64, use `-Dtarget=aarch64-linux-musl` instead. Plain local macOS
builds default to the same stable deployment target so cgo clients do not link
a test binary for an older macOS version than `libspore.dylib`.

Returned JSON strings are NUL-terminated for C convenience. The reported length
excludes the trailing NUL and includes the final newline, matching CLI JSON
output. Free returned strings with `spore_free_string` on the same context:

```c
SporeContext context = 0;
SporeOwnedString json = {0};

if (spore_context_new(&context) != SPORE_SUCCESS) return 1;
if (spore_host_info_json(context, &json) != SPORE_SUCCESS) return 1;

spore_free_string(context, json);
spore_context_free(context);
```

`spore_host_info_json` preserves the ARM-shaped `spore.host-info.v2`
contract and returns `SPORE_ERROR` with `UnsupportedArchitecture` on x86-64.
Use `spore_host_info_json_v3` for the architecture-discriminated contract on
either architecture. V3 reports GIC and counter facts only in its `arm64`
platform variant; its `amd64` variant instead reports the frozen board and CPU
profiles, low-RAM board limits, irqchip/PIT, virtio and generation layout, and
the bounded KVM capability predicate. The x86 KVM backend reports `available`
only when the complete approved capability predicate passes. Product execution
is still an experimental fresh-only profile requiring one vCPU and explicit
512 MiB memory; capture, resume, rootfs, networking, and build integration
remain unavailable until their later implementation slices land.

The Zig API follows the same split: `hostInfo` is the ARM-only v2
compatibility function and returns `error.UnsupportedArchitecture` on x86-64,
while `hostInfoV3` returns the discriminated contract on either architecture.
The standalone `libspore.run`, `runManaged`, and `createNamed` x86 paths remain
gated until Slice 3c; Slice 3a enables the shared implementation only for the
product CLI.

Options structs use `size` and `version` fields and should be initialized with
their matching helper:

```c
SporeInspectBundleOptions options;
spore_inspect_bundle_options_init(&options);
options.source = (SporeString){ .ptr = "file:///tmp/base.bundle", .len = 23 };
```

Inspecting a local `.spore` returns the same manifest summary as the Zig API,
including annotation key/value pairs:

```c
SporeInspectSporeOptions inspect;
spore_inspect_spore_options_init(&inspect);
inspect.spore_dir = (SporeString){ .ptr = "worker.spore", .len = 12 };

if (spore_inspect_spore_json(context, &inspect, &json) != SPORE_SUCCESS) return 1;
spore_free_string(context, json);
```

`spore_pull_json` follows the same owned-string contract and returns the
`spore.pull.result.v1` schema used by `spore --json pull`:

```c
SporePullOptions pull;
spore_pull_options_init(&pull);
pull.source = (SporeString){ .ptr = "file:///tmp/base.bundle", .len = 23 };
pull.out_dir = (SporeString){ .ptr = "/tmp/base.spore", .len = 15 };
pull.child_id = (SporeString){ .ptr = "0", .len = 1 };
pull.bundle_cache.kind = SPORE_CACHE_ROOT_NONE;

if (spore_pull_json(context, &pull, &json) != SPORE_SUCCESS) return 1;
spore_free_string(context, json);
```

Named lifecycle functions follow the same pattern:

```c
SporeCreateNamedOptions create;
spore_create_named_options_init(&create);
create.name = (SporeString){ .ptr = "worker-1", .len = 8 };
create.spore_executable = (SporeString){ .ptr = "/usr/local/bin/spore", .len = 20 };
SporeString initial_argv[] = {
    { .ptr = "/bin/worker", .len = 11 },
};
create.initial_argv = initial_argv;
create.initial_argc = 1;
create.initial_output = SPORE_INITIAL_OUTPUT_RETAIN;

uint16_t github_ports[] = {443};
SporeString allow_cidrs[] = {
    { .ptr = "93.184.216.34/32", .len = 16 },
};
SporeString allow_hosts[] = {
    { .ptr = "example.com", .len = 11 },
};
SporeNetworkRule rules[] = {
    {
        .host = { .ptr = "github.com", .len = 10 },
        .ports = github_ports,
        .port_count = 1,
    },
};
SporeBoundUnixService services[] = {
    {
        .name = { .ptr = "cleanroom-gateway", .len = 17 },
        .guest_host = { .ptr = "gateway.cleanroom.internal", .len = 26 },
        .guest_port = 8170,
        .unix_path = { .ptr = "/tmp/cleanroom-gateway.sock", .len = 27 },
    },
};
SporeAnnotation annotations[] = {
    {
        .key = { .ptr = "dev.buildkite.cleanroom.policy_hash", .len = 34 },
        .value = { .ptr = "sha256:abc123", .len = 13 },
    },
};
create.network_enabled = 1;
create.allow_cidrs = allow_cidrs;
create.allow_cidr_count = 1;
create.allow_hosts = allow_hosts;
create.allow_host_count = 1;
create.network_rules = rules;
create.network_rule_count = 1;
create.bound_unix_services = services;
create.bound_unix_service_count = 1;
create.annotations = annotations;
create.annotation_count = 1;

if (spore_create_named_json(context, &create, &json) != SPORE_SUCCESS) return 1;
spore_free_string(context, json);

SporeRestoreNamedOptions restore;
spore_restore_named_options_init(&restore);
restore.spore_dir = (SporeString){ .ptr = "worker-1.spore", .len = 14 };
restore.name = (SporeString){ .ptr = "worker-2", .len = 8 };
SporeBoundUnixServiceBinding bindings[] = {
    {
        .name = { .ptr = "cleanroom-gateway", .len = 17 },
        .unix_path = { .ptr = "/tmp/fresh-cleanroom-gateway.sock", .len = 33 },
    },
};
restore.bound_unix_services = bindings;
restore.bound_unix_service_count = 1;

if (spore_restore_named_json(context, &restore, &json) != SPORE_SUCCESS) return 1;
spore_free_string(context, json);
```

Named copy calls return only a result code and write details to the context last
error:

```c
SporeCopyNamedOptions copy;
spore_copy_named_options_init(&copy);
copy.name = (SporeString){ .ptr = "worker", .len = 6 };
copy.host_path = (SporeString){ .ptr = "./local.txt", .len = 11 };
copy.guest_path = (SporeString){ .ptr = "/tmp/local.txt", .len = 14 };

if (spore_copy_in_named(context, &copy) != SPORE_SUCCESS) return 1;
```

Set `SPOREVM_RUNTIME_DIR`, cache roots, and similar process settings with
`spore_context_set_env` before calling lifecycle functions.
Named lifecycle monitor subprocesses inherit the context environment.
The C ABI does not install a re-exec trampoline for the host application. Leave
`spore_executable` empty only when a matching `spore` CLI is available on
`PATH`, or set it to an executable that can dispatch SporeVM's hidden helper
roles.

## Go Binding

The first Go binding lives in [`bindings/go`](../bindings/go). It is a thin cgo
adapter over the C ABI, so `libspore` must be installed or discoverable through
`pkg-config`. The Go package installs the SporeVM re-exec trampoline in package
init. `CreateNamedOptions.SporeExecutable` and
`RestoreNamedOptions.SporeExecutable` normally stay empty; the binding fills
them with the current executable path so monitor and `netd` helpers re-exec the
same linked Go binary. Set `SporeExecutable` only when deliberately using an
external helper binary for migration or debugging.

```go
client, err := spore.New()
if err != nil {
    return err
}
defer client.Close()

if err := client.SetEnv(ctx, "SPOREVM_RUNTIME_DIR", runtimeDir); err != nil {
    return err
}

info, err := client.HostInfo(ctx)
if err != nil {
    return err
}

network, err := client.NetworkCapabilities(ctx)
if err != nil {
    return err
}
if !network.Supported || !network.ExactHostPort || !network.BoundServices {
    return fmt.Errorf("requested network policy is not supported by libspore")
}

bundle, err := client.InspectBundle(ctx, spore.InspectBundleOptions{
    Source: "file:///tmp/base.bundle",
})
if err != nil {
    return err
}

pulled, err := client.Pull(ctx, spore.PullOptions{
    Source: "file:///tmp/base.bundle",
    OutDir: "/tmp/base.spore",
    ChildID: "0",
})
if err != nil {
    return err
}

created, err := client.CreateNamed(ctx, spore.CreateNamedOptions{
    Name: "worker",
    InitialArgv: []string{"/bin/worker"},
    NetworkEnabled: true,
    AllowCIDRs: []string{"93.184.216.34/32"},
    AllowHosts: []string{"example.com"},
    NetworkRules: []spore.NetworkRule{{
        Host:  "github.com",
        Ports: []uint16{443},
    }},
    BoundServices: []spore.BoundUnixService{{
        Name:      "cleanroom-gateway",
        GuestHost: "gateway.cleanroom.internal",
        GuestPort: 8170,
        UnixPath:  "/tmp/cleanroom-gateway.sock",
    }},
    Annotations: map[string]string{
        "dev.buildkite.cleanroom.policy_hash": "sha256:abc123",
    },
})
if err != nil {
    return err
}

exec, err := client.ExecNamed(ctx, spore.ExecNamedOptions{
    Name: "worker",
    Argv: []string{"/bin/true"},
})
if err != nil {
    return err
}

if err := client.CopyInNamed(ctx, spore.CopyNamedOptions{
    Name:      "worker",
    HostPath:  "./local.txt",
    GuestPath: "/tmp/local.txt",
}); err != nil {
    return err
}

saved, err := client.SaveNamed(ctx, spore.SaveNamedOptions{
    Name:   "worker",
    OutDir: "worker.spore",
    Annotations: map[string]string{
        "dev.buildkite.cleanroom.save": "warm",
    },
})
if err != nil {
    return err
}

inspected, err := client.InspectSpore(ctx, spore.InspectSporeOptions{
    SporeDir: "worker.spore",
})
if err != nil {
    return err
}
workspace := inspected.Annotations["cleanroom.workspace"]

restored, err := client.RestoreNamed(ctx, spore.RestoreNamedOptions{
    SporeDir: "worker.spore",
    Name:     "worker-restored",
    BoundServiceBindings: []spore.BoundUnixServiceBinding{{
        Name:     "cleanroom-gateway",
        UnixPath: "/tmp/fresh-cleanroom-gateway.sock",
    }},
})
if err != nil {
    return err
}

named, err := client.ListNamed(ctx)
if err != nil {
    return err
}

removed, err := client.RemoveNamed(ctx, spore.RemoveNamedOptions{
    Name: "worker-restored",
})
if err != nil {
    return err
}

removedSave, err := client.RemoveSaved(ctx, spore.RemoveSavedOptions{
    SporeDir: "worker.spore",
})
if err != nil {
    return err
}

_ = info
_ = network
_ = bundle
_ = pulled
_ = created
_ = exec.ExitCode
_ = exec.Stdout
_ = exec.Stderr
_ = exec.NetworkEventsJSONL
_ = saved
_ = workspace
_ = restored
_ = named
_ = removed
_ = removedSave
```

The surface covers build info, context lifetime, host-info, network
capabilities, inspect-bundle, inspect-spore, pull, context-local environment
variables through `SetEnv`, and named lifecycle `CreateNamed`,
`InitialOutputNamed`, `ExecNamed`,
`OpenExecNamedStream`, `CopyInNamed`, `CopyOutNamed`, `SaveNamed`,
`RestoreNamed`, `RemoveNamed`, `RemoveSaved`, and `ListNamed`.
`CreateNamedOptions` exposes `InitialArgv`, `InitialOutput`, and the create-time network policy
supported by the C ABI: `NetworkEnabled`, `AllowCIDRs`, `AllowHosts`, exact
host/port `NetworkRules`, and `BoundServices` for host Unix sockets exposed to
the guest. Passing CIDRs, hosts, exact rules, or bound services while
`NetworkEnabled` is false is rejected by libspore instead of being silently
ignored.

`NetworkCapabilities` is the typed wrapper around
`spore_network_capabilities_json`. Call it before accepting a higher-level
policy so unsupported features can fail closed in the caller. Stage-scoped exec
network policy updates remain unsupported today:
`NetworkCapabilities.StagePolicyUpdate` is false, and the Go binding
intentionally omits per-exec network policy update options rather than exposing
a field that cannot be enforced. `ExecNamedResult` includes the exit code,
stdout, stderr, decoded network event JSONL, and truncation flags returned by
the C JSON payload.

When setting `SPOREVM_RUNTIME_DIR`, pass an absolute directory that exists and
is private to the current user, matching the named lifecycle registry rules.

The Go binding decodes the same JSON contracts as the CLI and C ABI where calls
return JSON, and exposes named copy as error-returning side-effect methods. It
requires an exact C ABI version 19 match. Go context cancellation is checked before
entering C calls; long-running runtime cancellation is not exposed until the Zig
product API and C ABI provide it.

From a source checkout, build `libspore` first and point Go at the generated
pkg-config and dynamic library paths:

```bash
mise run build
cd bindings/go
PKG_CONFIG_PATH="$PWD/../../zig-out/lib/pkgconfig" \
DYLD_LIBRARY_PATH="$PWD/../../zig-out/lib" \
go test -a ./...
```

Use `LD_LIBRARY_PATH` instead of `DYLD_LIBRARY_PATH` on Linux.

For a standalone named-lifecycle smoke from a checkout, run:

```bash
mise run smoke:libspore-standalone-go
```

The smoke builds a tiny Go embedder, signs it with the hypervisor entitlement on
macOS, removes `spore` from `PATH`, and runs plain plus network-enabled named VM
flows through the re-exec trampoline.

### Named Lifecycle Troubleshooting

- `MonitorVersionMismatch` means libspore reached a monitor helper, but the
  helper did not report the same SporeVM version and monitor helper contract.
  The match is exact, including patch releases, because the helper argv/control
  contract is private to one SporeVM build.
  Use the Go default self re-exec path, or point `SporeExecutable` /
  `spore_executable` at a matching `spore` binary.
- `spore` not found during C or Zig named lifecycle means the default
  `spore_executable` resolved through `PATH`. Install a matching CLI helper,
  set `spore_executable` explicitly, or provide an embedder trampoline
  equivalent to the Go binding's package init hook.
- On macOS HVF, sign the final embedder executable with
  `com.apple.security.hypervisor`. Signing only `libspore.dylib` is not enough
  because the monitor role is the re-execed embedder process.
- If a dynamically linked standalone embedder times out waiting for monitor
  readiness before any VM state appears, verify that the re-execed child can
  load `libspore`. Install the shared library in a normal loader path, embed an
  rpath, statically link, or pass the needed `DYLD_LIBRARY_PATH` /
  `LD_LIBRARY_PATH` through the libspore context environment with `SetEnv` or
  `spore_context_set_env`.
