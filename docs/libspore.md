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
```

Use the matching helper for owned results:

- `deinitHostInfo`
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
- `deinitRootfsResolveResult`
- `deinitRootfsCasPreloadResult`
- `deinitRootfsSystemSummary`
- `deinitRootfsPruneResult`

`run`, `runManaged`, `runFromSpore`, and `resumeSpore` return value results and
do not need deinit.

## Local Spore Inspection

Use `inspectSpore` to read metadata from a local `.spore` directory without
resuming it or manually parsing `manifest.json`:

```zig
const inspected = try libspore.inspectSpore(allocator, "worker.spore");
defer libspore.deinitSporeInspectResult(allocator, inspected);

const workspace = inspected.annotations.map.get("cleanroom.workspace");
```

`SporeInspectResult.annotations` is an opaque key/value map copied out of the
validated manifest. SporeVM does not interpret namespaces such as
`cleanroom.*`; callers own their schema. The same manifest annotation rules
apply on read and write: keys and values must be UTF-8 strings, keys cannot be
empty, and the serialized annotation object is capped at 64 KiB.

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
});
defer libspore.deinitRootfsResolveResult(allocator, resolved);
```

`rootfsImportOci` imports OCI layouts under local refs. `rootfsCasPreload`
preloads a rootfs digest into chunked CAS storage and can attach the resulting
descriptor to an existing spore.

## Running

Use `runManaged` for the high-level `spore run` path:

```zig
const result = try libspore.runManaged(init, allocator, .{
    .image_ref = "docker.io/library/alpine:3.20",
    .command = &.{ "/bin/true" },
});
```

Use `runFromSpore` for `spore run --from` semantics:

```zig
const result = try libspore.runFromSpore(context, allocator, .{
    .spore_dir = "base.spore",
    .command = &.{ "/bin/true" },
});
```

Leave `.command` empty to attach to the captured default session. Set
`.interactive = true` or `.tty = true` only when that captured session was
started with interactive stdin or a PTY; unsupported input attach returns a
guest exit error instead of silently downgrading to output-only attach.

`RunResult.memory_restore_source` and `memory_restore_reason` are populated for
`runFromSpore` and `resumeSpore`, so embedders can tell whether RAM came from
`local_backing` or verified `chunks` without parsing logs.

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

var snapshot_annotations = libspore.Annotations{};
try snapshot_annotations.map.put(allocator, "dev.buildkite.cleanroom.snapshot", "warm");
const snap = try libspore.snapshotNamed(context, allocator, .{
    .name = "worker-1",
    .out_dir = "worker-1.spore",
    .continue_after = true,
    .annotations = snapshot_annotations,
});
defer libspore.deinitNamedLifecycleResult(allocator, snap);

const resumed = try libspore.resumeNamed(init, allocator, .{
    .spore_dir = "worker-1.spore",
    .name = "worker-2",
});
defer libspore.deinitNamedLifecycleResult(allocator, resumed);

const forked = try libspore.forkNamed(init, allocator, .{
    .source_name = "worker-2",
    .count = 2,
    .name_pattern = "worker-child-%d",
});
defer libspore.deinitNamedForkResult(allocator, forked);
```

For mutable image refs, Zig callers can set `.image_pull_policy` to `.missing`,
`.always`, or `.never`; the C and Go bindings use the default `.missing`
policy.

The named surface is:

- `createNamed`
- `resumeNamed`
- `forkNamed`
- `execNamed`
- `snapshotNamed`
- `suspendNamed`
- `removeNamed`
- `listNamed`

`snapshotNamed` currently supports snapshot-and-continue only. Use
`deinitNamedLifecycleResult`, `deinitExecNamedResult`,
`deinitNamedForkResult`, and `deinitNamedList` for owned results.
`execNamed` returns a bounded stdout/stderr result, so `.interactive = true` or
`.tty = true` returns `error.UnsupportedInteractiveExec` in this slice. Use the
CLI for streaming named exec until a streaming embedder API is added.

## Networking

See [SporeVM Networking](networking.md) for the CLI policy and manifest
contract.

Call `networkCapabilities()` before accepting user policy:

```zig
const caps = libspore.networkCapabilities();
if (!caps.supported or !caps.exact_host_port) return error.UnsupportedNetworkPolicy;
```

The first networking slice supports TCP IPv4, DNS A-record learning, exact
host-plus-port policy, default deny policy, bound Unix services, and named exec
decision-event capture. It does not support IPv6, UDP egress, wildcard hosts,
CIDR in Cleanroom policy, SNI/HTTP matching, or live per-exec policy updates.

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

const created = try libspore.createNamed(init, allocator, .{
    .name = "cr-test",
    .image_ref = "docker.io/library/alpine:3.20",
    .network = .{
        .enabled = true,
        .policy = policy,
        .bound_services = &.{service},
    },
});
defer libspore.deinitNamedLifecycleResult(allocator, created);
```

`execNamed(.{ .network_policy = ... })` is part of the API contract but returns
`error.UnsupportedNetworkPolicyUpdate` in this slice. Callers that need
stage-scoped networking should start the VM with a single all-stage policy, or
reject stage-scoped policy until `networkCapabilities().stage_policy_update`
is true.

`ExecNamedResult.network_events_jsonl` contains decoded JSONL network events
captured during the exec window. Bound service declarations are recorded in
captured manifests as restore-time requirements without host socket paths. On
restore, callers provide fresh live bindings keyed by service name:

```zig
const resumed = try libspore.resumeNamed(init, allocator, .{
    .spore_dir = "cr-test.spore",
    .name = "cr-test-resumed",
    .bound_services = &.{.{
        .name = "cleanroom-gateway",
        .target = .{ .unix = "/tmp/fresh-cleanroom-gateway.sock" },
    }},
});
defer libspore.deinitNamedLifecycleResult(allocator, resumed);
```

The manifest remains portable: it records the service name, guest host, and
guest port, while the restore option supplies only the current host socket path.
Restore fails closed if any declared service lacks a live binding, if a binding
does not match a declared service name, or if duplicate bindings are supplied.
The Zig `runFromSpore` and `resumeSpore` options use the same `.bound_services`
restore field.

## Events

Run and resume calls accept a synchronous `EventSink`:

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
        .capture => |capture| _ = capture.capture_path,
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
host socket paths, and successful snapshots emit `.capture` before `.exit`.
Every run emits at most one completion event: `exit` for guest completion or
`failure` for a SporeVM failure.

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
inspect-bundle JSON, inspect-spore JSON, pull JSON, and named lifecycle JSON.

Release builds publish separate `libspore_Linux_arm64` and
`libspore_Darwin_arm64` archives so CLI-only installs do not carry development
files. Each libspore archive contains:

- `include/spore.h`
- `lib/libspore.a`
- the platform shared library under `lib/`
- `lib/pkgconfig/libspore.pc`
- this guide and the project license

Use the archive that matches the target platform:

```bash
asset=libspore_Darwin_arm64 # or libspore_Linux_arm64
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

SporeResumeNamedOptions resume;
spore_resume_named_options_init(&resume);
resume.spore_dir = (SporeString){ .ptr = "worker-1.spore", .len = 14 };
resume.name = (SporeString){ .ptr = "worker-2", .len = 8 };
SporeBoundUnixServiceBinding bindings[] = {
    {
        .name = { .ptr = "cleanroom-gateway", .len = 17 },
        .unix_path = { .ptr = "/tmp/fresh-cleanroom-gateway.sock", .len = 33 },
    },
};
resume.bound_unix_services = bindings;
resume.bound_unix_service_count = 1;

if (spore_resume_named_json(context, &resume, &json) != SPORE_SUCCESS) return 1;
spore_free_string(context, json);
```

Set `SPOREVM_RUNTIME_DIR`, cache roots, and similar process settings with
`spore_context_set_env` before calling lifecycle functions.

## Go Binding

The first Go binding lives in [`bindings/go`](../bindings/go). It is a thin cgo
adapter over the C ABI, so `libspore` must be installed or discoverable through
`pkg-config`.

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

snap, err := client.SnapshotNamed(ctx, spore.SnapshotNamedOptions{
    Name:     "worker",
    OutDir:   "worker.spore",
    Continue: true,
    Annotations: map[string]string{
        "dev.buildkite.cleanroom.snapshot": "warm",
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

resumed, err := client.ResumeNamed(ctx, spore.ResumeNamedOptions{
    SporeDir: "worker.spore",
    Name:     "worker-resumed",
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
    Name: "worker-resumed",
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
_ = snap
_ = workspace
_ = resumed
_ = named
_ = removed
```

The surface covers build info, context lifetime, host-info, network
capabilities, inspect-bundle, inspect-spore, pull, context-local environment
variables through `SetEnv`, and named lifecycle `CreateNamed`, `ExecNamed`,
`SnapshotNamed`, `ResumeNamed`, `RemoveNamed`, and `ListNamed`.
`CreateNamedOptions` exposes the create-time network policy supported by the C
ABI: `NetworkEnabled`, `AllowCIDRs`, `AllowHosts`, exact host/port
`NetworkRules`, and `BoundServices` for host Unix sockets exposed to the guest.
Passing CIDRs, hosts, exact rules, or bound services while `NetworkEnabled` is
false is rejected by libspore instead of being silently ignored.

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

The Go binding decodes the same JSON contracts as the CLI and C ABI, and it
requires C ABI version 10 or newer. Go context cancellation is checked before
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
