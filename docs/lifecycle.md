# Named Lifecycle

Named lifecycle keeps a VM alive behind one local monitor process so callers can
create a warmed guest, run repeated commands, save it as a spore, restore it
under a new name, and remove it without learning the monitor socket protocol.

## User Contract

```bash
spore create bench-1 --image docker.io/library/alpine:3.20 'sleep 30'
spore exec bench-1 'echo hi'
spore save bench-1 --out bench-1.spore --stop
spore restore bench-1.spore --name bench-2
spore ps
spore rm bench-2
```

`spore run` remains the one-shot command. The stable named surface is
`create`, `exec`, `copy-in`, `copy-out`, `save`, `restore`,
`fork --vm`, `ls`/`ps`, and `rm` on supported HVF and KVM hosts.
One-shot `spore run --image SOURCE --commit local/name:tag -- COMMAND` publishes
successful disk preparation as an image; it does not create or name a live VM.
Use named `create`/`copy-in`/`exec`/`save` when preparation needs multiple
interactive lifecycle operations.

Machine callers use global `--json` for single-result lifecycle commands:

```bash
spore --json create bench-1 --image docker.io/library/alpine:3.20
spore --json ls
```

`spore create`, `spore exec`, and `spore run` accept a shell command by default
and `-- <argv...>` for exact argv. Shell-form commands require a guest
environment with `/bin/sh`; the managed default initrd provides a small Toybox
shell environment, while image, rootfs, and custom-initrd guests provide their
own command environment. Use `--image` or `--rootfs` for general distro
commands. A command passed to `spore create` is
started in the guest and detached; stdout and stderr are discarded so the named
VM is immediately available for `fork`, `exec`, `save`, and `rm`. `spore
exec` always streams guest stdout and stderr live as independent ordered
streams. Stdin is closed by default. Pass `-i` to forward host stdin, and pass
`-t` to request a guest terminal for the exec. The usual shell spelling is:

```bash
spore exec -it bench-1 -- /bin/sh
```

`-i` and `-t` are independent: neither flag selects output attachment, and a
host terminal is not required when PTY output or input is redirected.

Exact argv does not perform guest PATH lookup. Use `-- /bin/echo hi`, not
`-- echo hi`, unless the guest environment itself can execute `echo` at that
exact path.

Named create exposes the same create-time annotation and networking options as
the lifecycle library:

```bash
spore create bench-1 \
  --image docker.io/library/alpine:3.20 \
  --annotation cleanroom.stage=compile \
  --net \
  --allow-host-port github.com:443 \
  --bind-service metadata:8170=unix:/tmp/metadata.sock
```

`--annotation KEY=VALUE` can be repeated. `--allow-host-port HOST:PORT` adds an
exact DNS-learned host plus TCP port egress rule. `--bind-service
NAME[:PORT]=unix:/path.sock` exposes a host Unix stream socket to the guest as
`NAME.spore.internal`, defaulting to port 80 when `PORT` is omitted. Host socket
paths are live monitor state only; saved manifests record the service name,
guest host, and guest port as restore-time requirements.

Tooling can provide the same create options as JSON:

```bash
spore create bench-1 --options @create-options.json
```

```json
{
  "schema_version": 1,
  "image": "docker.io/library/alpine:3.20",
  "memory": "512mb",
  "vcpus": 2,
  "timeout_ms": 120000,
  "network": {
    "enabled": true,
    "allow_cidrs": ["93.184.216.34/32"],
    "allow_hosts": ["example.com"],
    "network_rules": [{ "host": "github.com", "ports": [443] }],
    "bound_services": [
      {
        "name": "metadata",
        "guest_host": "metadata.spore.internal",
        "guest_port": 8170,
        "unix_path": "/tmp/metadata.sock"
      }
    ]
  },
  "annotations": {
    "cleanroom.stage": "compile"
  }
}
```

The file uses the same spellings as the CLI flags: `image`, `rootfs`, `kernel`,
`initrd`, `pull`, and `memory`. Unknown fields fail closed, `schema_version`
must be `1`, and `--options` cannot be combined with individual create option
flags. Bound services default `guest_host` to `NAME.spore.internal` when it is
omitted.

Named VMs also support explicit path transfer through the same local
monitor boundary:

```bash
spore copy-in bench-1 ./local.txt /tmp/local.txt
spore copy-out bench-1 /tmp/local.txt ./roundtrip.txt
spore copy-in bench-1 ./src /tmp/src
spore copy-out bench-1 /tmp/src ./src-roundtrip
```

Copy paths are explicit on both sides. Guest paths must be absolute, `.` and
`..` components are rejected, sources must be regular files or directories, and
destinations must not already exist. Symlinks and special files are rejected.

## Runtime State

Live VM state is runtime state, not cache state:

```text
$SPOREVM_RUNTIME_DIR/vms/<name>/
  control.sock
  pid
  spec.json
  ready.json
  create-timing.json
  monitor-timing.json
  monitor-stats.json
  console.log                 # only with --console-log
  monitor.log
```

If `SPOREVM_RUNTIME_DIR` is unset, SporeVM uses the platform runtime directory
or a private temp fallback. Runtime directories must be private to the current
user. Stale entries fail closed unless the recorded monitor pid is dead and the
user removes or recreates the VM.

Each VM has one monitor process. The monitor owns the hypervisor VM, vCPU loop,
virtio state, rootfs fd, writable disk state, optional configured console log,
monitor log, vsock state, optional network gateway, and a local newline-delimited
JSON control socket. `ready.json`, list output, and lifecycle results report a
console path only when the monitor actually opened one. Restore never reuses a
saved lifecycle console path as host authority; a future explicit restore option
would need to select a new path.

## Session Handles

Spore session handles are low-level process/session handles, not workflow
state. Saved manifests can record `sessions`: an `id`, `kind: "process"`,
and stream capabilities for `stdin`, `stdout`, `stderr`, and `terminal`.
Fresh `spore run --save` calls create a new output directory and record the
`default` session. Commands started from an existing spore record a generated
`run-*` session id, so a save of that
restored command can be reattached without pretending it is the original default
process.

`spore attach DIR` attaches to the `default` handle when present, or to the sole
recorded handle when a spore only has one non-default session. `spore fork`
preserves the recorded handles in each child. The handle
records guest-side capability only: host stdin, the host-side PTY owner, raw
terminal mode, window ownership, and any currently attached client are not part
of a spore.

If `spore attach -i DIR` or `spore attach -t DIR` asks for input that
the recorded handle cannot support, SporeVM rejects the request before restore.
Starting a new command with `spore run --from DIR <command>` starts a new
process session instead of reattaching to an existing handle; `-t` for that
new-command path remains deferred. `spore run --from DIR --generation FILE <command>`
publishes run-specific fan-out identity before that fresh command
starts. Named VM names remain lifecycle monitor handles.

## Saves And Forks

`spore save NAME --out DIR` writes a spore and leaves the named VM running.
Writable-disk saves are machine-local by default: host-private lifecycle
metadata names an opaque durable pin in the configured rootfs cache. The pin
roots the immutable disk index and chunks independently of the save path, so
moving or renaming the directory is safe. A raw filesystem copy retains the
same pin identity; it is not independently removable, and removing either copy
through SporeVM may invalidate the other. Use `spore fork` for an independent
machine-local lifecycle or pack/unpack for a self-contained portable artifact.
Offline fork children instead share RAM through the batch-owned
`shared-chunks` directory. Move the complete batch, not an individual child;
pack/unpack is the supported independently portable child boundary.
Non-destructive save supports both single-vCPU and multi-vCPU named VMs on every
supported backend (KVM and HVF), for diskless, image-created writable rootfs, and
explicit `--rootfs PATH` VMs: the monitor quiesces every vCPU at one barrier,
captures manifest-v1 machine state, and resumes the guest. As with `--stop` and
live fork, KVM writes a portable multi-vCPU spore while HVF writes a
same-backend spore that restores only on HVF. `spore save NAME --out DIR --stop`
writes a spore and removes the named VM from the runtime registry. A failed save
leaves no partial spore at `--out`; if the capture itself fails, the monitor
stops the VM and the command reports the error (parity with single-vCPU save).
Named saves try the global cache lock before pausing any vCPU. While the lock
is contended, the request stays pending and the guest continues running; the
same acquired lock then spans capture and durable publication. Named saves
report the complete source-pause time through manifest/pin
authorization, active baseline-lease handoff, lifecycle metadata, final rename,
and destination-parent sync. Cache-lock wait and each publication phase are
logged separately, so backend RAM/disk capture time is not mistaken for the
full pause experienced by the guest.
Repeated `--annotation KEY=VALUE` flags merge save-time annotations into the
manifest without dropping create-time annotations:

```bash
spore save bench-1 --out bench-1.spore --stop --annotation saved=true
```

Delete a machine-local saved spore with `spore rm --spore DIR`. Diskless saves
have no pin, so removal validates the manifest, deletes the directory, and
durably syncs its parent. Disk-backed removal keeps the cache lock while it
validates the pin, deletes the visible save, syncs the parent, and unregisters
the pin. Raw `rm -rf` cannot make live CAS data collectable, but it leaks a
disk pin. `spore cache pins` lists pin IDs and canonical-index health; it does
not track save paths or claim to detect orphans. An operator who already knows
that an exact pin ID is unused may remove it with the expert-only
`spore cache unpin PIN_ID --force`; this can invalidate every raw copy sharing
that identity.

`spore cache pins` reports `index_valid` only after validating the record and
canonical index. It deliberately does not stat or hash every object; lazy reads
and `spore pack` still verify object bytes and may fail closed on missing or
corrupt content. There is no global save-reference registry in this pre-1.0
contract.

If a saved manifest declares bound services, named restore requires fresh host
socket bindings:

```bash
spore restore bench-1.spore --name bench-2 \
  --bind-service metadata=unix:/tmp/fresh-metadata.sock
```

`spore snapshot` is not a public command. Live named fork captures RAM and
machine state once while the source VM is paused, then keeps the source VM
running:

```bash
spore create counter --image docker.io/library/alpine:3.20 \
  'i=0; while true; do echo "$i" > /tick; i=$((i + 1)); sleep 1; done'
spore fork --vm counter --count 2 --name worker-%d
spore exec worker-0 'cat /tick; sleep 1; cat /tick'
```

`--name` is required with `--vm`. For `--count > 1`, it must contain exactly one
`%d`-style integer placeholder. SporeVM validates every child name before
pausing the source VM. A batch contains at most 32 children.

Disk-backed live fork supports the single writable rootfs device used by
image-created, explicit-rootfs, restored, and previously forked named VMs. The
source monitor drains the block queue, creates every child disk head at the
same paused epoch, and resumes the source without sealing a durable disk
snapshot. A live head with physical overrides requires native APFS or Linux
reflink cloning by default. After a successful save commits the exact canonical
baseline, a fork with no later overrides instead gives each child a fresh
sparse head and needs neither filesystem cloning nor slow-copy. Use
`--allow-slow-copy` only when a full dirty-overlay copy is acceptable; without
that explicit opt-in, unavailable native cloning of required overrides fails
closed.

Anonymous writable overlays, fork heads, and lazy sparse rootfs bases use the
absolute `TMPDIR` when it is set, falling back to `/tmp`. Put `TMPDIR` on the
reflink-capable scratch filesystem intended for fast fork. SporeVM retains that
factory root with each live writable disk and rejects a claimed child overlay
from a different filesystem before publishing readiness.

Each child receives a private one-use disk-head claim plus an independently
rooted baseline lease. The child reopens that baseline and adopts the claimed
overlay before it writes `ready.json`, so a successful fork never reports a
child whose disk handoff can still fail. The lease also means children remain
readable, forkable, and saveable after the source is removed and rootfs cache
GC/prune runs. Claims are transient runtime state and are not written into
durable spores.

Global JSON output exposes the phases separately:

```bash
spore --json fork --vm counter --count 2 --name worker-%d
```

The result includes `ram_capture_ms`, `disk_fork_ms`, `source_pause_ms`, and
`child_ready_ms` for disk-backed forks. Diskless forks return null for those
phase fields.

Named saves support diskless VMs, image-created writable rootfs state, and
explicit `--rootfs PATH` saves backed by exact immutable rootfs artifacts.
Supported backends can create, save with `--stop`, restore, and live-fork
fixed-RAM multi-vCPU named VMs. Child VMs preserve the source VM's vCPU count.
Networked named live fork remains unsupported.

## Monitor Boundary

The monitor protocol is local-only and protected by private runtime-directory
permissions. There is no TCP control socket and no central `spore daemon`.
Unknown monitor request types fail closed. `spore ls` reads monitor-published
metadata such as `monitor-stats.json`; unavailable stats render as unknown
instead of forcing an expensive VM memory scan.

`spore create`, `spore restore --name`, and `spore fork --vm` report success
only after the restored guest agent has answered a dedicated readiness request,
the monitor has written `ready.json`, the recorded PID is alive, and the local
`control.sock` answers a `hello` request with the same SporeVM version as the
linked library. This means a successful named restore is immediately ready for
`spore exec`; callers do not need to poll with a no-op command. For disk-backed
fork children, the baseline and one-shot `SCM_RIGHTS` overlay claim are validated
and adopted before that guest readiness probe succeeds. The monitor argv and
control protocol are a private
same-version contract, so matching is exact: a libspore `1.5.0` caller cannot
use a `spore` executable reporting `1.3.0`, even if PATH resolves that older
binary. Version mismatch is a startup error that names both versions and the
resolved executable path.

Named lifecycle failures include the last known lifecycle state, recorded PID
when present, the configured console path when one exists, `monitor.log`, and
the control socket path where useful. This is the same diagnostic state visible
through `spore ls`, carried back to the caller that hit the lifecycle error.

`spore --json restore` includes `timing.prepare_ms`,
`timing.spawn_monitor_ms`, `timing.wait_exec_ready_ms`, and `timing.total_ms`.
The command returns after the exec-ready point, so `timing.total_ms` is the
in-process restore-to-readiness measurement; external callers can separately
measure CLI process wall time.

Monitor processes deny child process execution through an embedded macOS
sandbox profile or Linux seccomp filter after optional startup helpers are
spawned. `mise run smoke:monitor-jail` covers the denied-operation path.

## Limits

- Named exec command requests are bounded to 8,191 encoded bytes including
  guest framing. There is no smaller per-argument cap; usable command length
  varies with argv count and JSON escaping. Put larger commands in a guest
  script.
- `spore run -i` supports pipe-style stdin forwarding for one-shot runs.
- `spore run -t` allocates a guest PTY for one-shot runs, and `spore run -it`
  forwards host terminal input in raw mode. TTY mode has one merged terminal
  output stream; JSONL emits it as `event:"terminal"`.
- `spore attach -i` and `spore attach -t` can attach to saved live sessions
  only when that session was originally started with interactive stdin or a PTY.
  `spore run --from <spore-dir> <command>` starts a new command from saved VM
  state. `--generation FILE` is accepted only with `--from`. `spore run -t
  --from <spore-dir> <command>` is not implemented yet.
- Every attached `spore exec` uses the streaming monitor request. Embedders use
  `openExecNamedStream` for the same separate stdout/stderr, optional stdin,
  terminal, resize, exit, and monitor-error surface. The monitor uses fail-fast
  backpressure: a disconnected consumer or local socket that cannot accept a
  complete frame within the 25 ms send deadline aborts that exec so it cannot
  block the VM control loop indefinitely.
- The bounded `execNamed` compatibility collector returns owned byte slices to
  Zig. Its C JSON result keeps valid UTF-8 stdout and stderr as strings and
  represents invalid UTF-8 streams as integer byte arrays; the Go binding
  accepts both forms without changing the bytes.
- `spore copy-in` and `spore copy-out` transfer explicit regular files or
  directory trees. Symlinks, special files, overwrite, and workspace sync are
  intentionally outside this primitive. Embedders use the matching
  `copyInNamed`/`copyOutNamed` libspore API.
- `spore attach` connects to saved sessions in spores. Attaching to an
  already-running named VM remains outside the public CLI surface.
- Named live fork accepts at most 32 children and one writable rootfs disk.
  Networked and additional-device layouts remain unsupported.
- No live network-flow save/restore.
- No OCI `Entrypoint`, `Cmd`, or `User` semantics. Callers pass explicit argv.

## Validation

Useful focused checks:

```bash
mise run smoke:lifecycle
mise run smoke:lifecycle-copy
mise run smoke:lifecycle-tty
mise run smoke:lifecycle-auto-memory
mise run smoke:monitor-jail
mise run smoke:monitor-failure-modes
mise run smoke:named-disk-fork
scripts/benchmark/sporevm-lifecycle.sh
scripts/benchmark/sporevm-lifecycle.sh --backend kvm --image docker.io/library/node:22-bookworm-slim -n 3 --max-cleanup-ms 1000
```
