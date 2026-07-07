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
exec` forwards guest stdout and stderr as workload streams. Pass `-i` to stream
host stdin through the monitor to the guest process, and pass `-t` to request a
guest terminal for the exec. The usual shell spelling is:

```bash
spore exec -it bench-1 -- /bin/sh
```

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
  console.log
  monitor.log
```

If `SPOREVM_RUNTIME_DIR` is unset, SporeVM uses the platform runtime directory
or a private temp fallback. Runtime directories must be private to the current
user. Stale entries fail closed unless the recorded monitor pid is dead and the
user removes or recreates the VM.

Each VM has one monitor process. The monitor owns the hypervisor VM, vCPU loop,
virtio state, rootfs fd, writable disk state, console log, monitor log, vsock
state, optional network gateway, and a local newline-delimited JSON control
socket.

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
new-command path remains deferred. Named VM names remain lifecycle monitor
handles.

## Saves And Forks

`spore save NAME --out DIR` writes a spore and leaves the named VM running.
Non-destructive save supports both single-vCPU and multi-vCPU named VMs on every
supported backend (KVM and HVF), for diskless, image-created writable rootfs, and
explicit `--rootfs PATH` VMs: the monitor quiesces every vCPU at one barrier,
captures manifest-v1 machine state, and resumes the guest. As with `--stop` and
live fork, KVM writes a portable multi-vCPU spore while HVF writes a
same-backend spore that restores only on HVF. `spore save NAME --out DIR --stop`
writes a spore and removes the named VM from the runtime registry. A failed save
leaves no partial spore at `--out`; if the capture itself fails, the monitor
stops the VM and the command reports the error (parity with single-vCPU save).
Repeated `--annotation KEY=VALUE` flags merge save-time annotations into the
manifest without dropping create-time annotations:

```bash
spore save bench-1 --out bench-1.spore --stop --annotation saved=true
```

If a saved manifest declares bound services, named restore requires fresh host
socket bindings:

```bash
spore restore bench-1.spore --name bench-2 \
  --bind-service metadata=unix:/tmp/fresh-metadata.sock
```

`spore snapshot` is not a public command; live named fork uses an internal
snapshot-and-continue monitor action so the source VM keeps running:

```bash
spore create counter --image docker.io/library/alpine:3.20 \
  'i=0; while true; do echo "$i" > /tick; i=$((i + 1)); sleep 1; done'
spore fork --vm counter --count 2 --name worker-%d
spore exec worker-0 'cat /tick; sleep 1; cat /tick'
```

`--name` is required with `--vm`. For `--count > 1`, it must contain exactly one
`%d`-style integer placeholder. SporeVM validates every child name before
pausing the source VM.

Named saves support diskless VMs, image-created writable rootfs state, and
explicit `--rootfs PATH` saves backed by exact immutable rootfs artifacts.
Supported backends can create, save with `--stop`, restore, and live-fork
fixed-RAM multi-vCPU named VMs. Named live fork is still diskless-only; child
VMs preserve the source VM's vCPU count.

## Monitor Boundary

The monitor protocol is local-only and protected by private runtime-directory
permissions. There is no TCP control socket and no central `spore daemon`.
Unknown monitor request types fail closed. `spore ls` reads monitor-published
metadata such as `monitor-stats.json`; unavailable stats render as unknown
instead of forcing an expensive VM memory scan.

`spore create`, `spore restore --name`, and `spore fork --vm` report success
only after the monitor has written `ready.json`, the recorded PID is alive, and
the local `control.sock` answers a `hello` request with the same SporeVM version
as the linked library. The monitor argv and control protocol are a private
same-version contract, so matching is exact: a libspore `1.5.0` caller cannot
use a `spore` executable reporting `1.3.0`, even if PATH resolves that older
binary. Version mismatch is a startup error that names both versions and the
resolved executable path.

Named lifecycle failures include the last known lifecycle state, recorded PID
when present, `console.log`, `monitor.log`, and the control socket path where
useful. This is the same diagnostic state visible through `spore ls`, carried
back to the caller that hit the lifecycle error.

Monitor processes deny child process execution through an embedded macOS
sandbox profile or Linux seccomp filter after optional startup helpers are
spawned. `mise run smoke:monitor-jail` covers the denied-operation path.

## Limits

- `spore run -i` supports pipe-style stdin forwarding for one-shot runs.
- `spore run -t` allocates a guest PTY for one-shot runs, and `spore run -it`
  forwards host terminal input in raw mode. TTY mode has one merged terminal
  output stream; JSONL emits it as `event:"terminal"`.
- `spore attach -i` and `spore attach -t` can attach to saved live sessions
  only when that session was originally started with interactive stdin or a PTY.
  `spore run --from <spore-dir> <command>` starts a new command from saved VM
  state. `spore run -t --from <spore-dir> <command>` is not implemented yet.
- `spore exec -i/-t` uses a streaming monitor request. Embedders use
  `openExecNamedStream` for the same stdin, terminal, resize, exit, and
  monitor-error surface.
- `spore copy-in` and `spore copy-out` transfer explicit regular files or
  directory trees. Symlinks, special files, overwrite, and workspace sync are
  intentionally outside this primitive. Embedders use the matching
  `copyInNamed`/`copyOutNamed` libspore API.
- `spore attach` connects to saved sessions in spores. Attaching to an
  already-running named VM remains outside the public CLI surface.
- No disk-backed or networked named live fork yet.
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
scripts/benchmark-sporevm-lifecycle.sh
```
