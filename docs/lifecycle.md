# Named Lifecycle

Named lifecycle keeps a VM alive behind one local monitor process so callers can
create a warmed guest, run repeated commands, checkpoint it, resume it under a
new name, and remove it without learning the monitor socket protocol.

## User Contract

```bash
spore create bench-1 --image docker.io/library/alpine:3.20 'sleep 30'
spore exec bench-1 'echo hi'
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
spore ps
spore rm bench-2
```

`spore run` remains the one-shot command. The stable named surface is
`create`, `exec`, `suspend`, `resume --name`, `fork --vm`, `ls`/`ps`, and `rm` on
supported HVF and KVM hosts.

Machine callers use global `--json` for single-result lifecycle commands:

```bash
spore --json create bench-1 --image docker.io/library/alpine:3.20
spore --json ls
```

`spore create`, `spore exec`, and `spore run` accept a shell command by default
and `-- <argv...>` for exact argv. A command passed to `spore create` is
started in the guest and detached; stdout and stderr are discarded so the named
VM is immediately available for `fork`, `exec`, `suspend`, and `rm`. `spore
exec` forwards guest stdout and stderr as workload streams.

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
```

If `SPOREVM_RUNTIME_DIR` is unset, SporeVM uses the platform runtime directory
or a private temp fallback. Runtime directories must be private to the current
user. Stale entries fail closed unless the recorded monitor pid is dead and the
user removes or recreates the VM.

Each VM has one monitor process. The monitor owns the hypervisor VM, vCPU loop,
virtio state, rootfs fd, writable disk state, console log, vsock state, optional
network gateway, and a local newline-delimited JSON control socket.

## Checkpoints And Forks

`spore suspend NAME --out DIR` consumes the named VM and writes a spore.
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

Named checkpoints support diskless VMs, image-created writable rootfs state, and
explicit `--rootfs PATH` checkpoints backed by exact immutable rootfs artifacts.
Supported backends can create, suspend, and resume fixed-RAM multi-vCPU named
VMs. Named live fork is currently single-vCPU and diskless-only.

## Monitor Boundary

The monitor protocol is local-only and protected by private runtime-directory
permissions. There is no TCP control socket and no central `spore daemon`.
Unknown monitor request types fail closed. `spore ls` reads monitor-published
metadata such as `monitor-stats.json`; unavailable stats render as unknown
instead of forcing an expensive VM memory scan.

Monitor processes deny child process execution through an embedded macOS
sandbox profile or Linux seccomp filter after optional startup helpers are
spawned. `mise run smoke:monitor-jail` covers the denied-operation path.

## Limits

- `spore run -i` supports pipe-style stdin forwarding for one-shot runs.
- `spore run -t` allocates a guest PTY for one-shot runs, and `spore run -it`
  forwards host terminal input in raw mode. TTY mode has one merged terminal
  output stream; JSONL emits it as `event:"terminal"`.
- `spore run -i --from` and `spore run -t --from` can attach to captured live
  sessions only when that session was originally started with interactive stdin
  or a PTY. `spore run -t --from <command>` and named interactive
  `spore exec -it` are not implemented yet.
- No multi-vCPU named live fork yet.
- No disk-backed or networked named live fork yet.
- No live network-flow checkpointing.
- No OCI `Entrypoint`, `Cmd`, or `User` semantics. Callers pass explicit argv.

## Validation

Useful focused checks:

```bash
mise run smoke:lifecycle
mise run smoke:lifecycle-auto-memory
mise run smoke:monitor-jail
mise run smoke:monitor-failure-modes
scripts/benchmark-sporevm-lifecycle.sh
```
