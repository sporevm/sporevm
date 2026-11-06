# Minimal Exec Initrd

These sources build the small SporeVM guest control plane embedded into the
`spore` binary. The agent runs as `/init`, mounts the rootfs, network, and
build disks the kernel command line asks for, then serves host requests over
vsock.

## Protocol

For each request the host opens a vsock stream to port 10700 (or
`cleanroom_guest_port=`) and writes one JSON object and a newline, at most
8191 bytes. Each request type has a fixed member set: every member must appear
exactly once, and missing, unknown, or duplicate members, trailing bytes, or a
missing newline make it a bad request. After the newline both directions carry
SPIO frames: a 24-byte little-endian header (`SPIO`, version 1, frame type,
zero flags, stream id, byte offset, payload length of at most 4096) and the
payload. The streams are control (0), stdin (1), stdout (2), stderr (3), and
terminal (4). Every reply ends with an exit frame; a failed request first
writes its error to stderr. With `spore_console_mirror=1` on the kernel
command line, which the host passes only when it logs the console
(`--console-log`), the agent also copies command output to the console.

| Request | Does |
| --- | --- |
| `ready` | exits 0 if the rootfs and network the VM asked for are usable |
| `start-v1` | starts a command as the VM's session, or in the background with `detached`; `stdio` is `null`, `pipe` (stdin frames), or `tty` (a PTY on the terminal stream, resized by resize frames); `params_json` applies new generation identity first |
| `attach-v1` | reattaches to a session, replaying output from the given offsets if they are within the last 64 KiB of each stream; `params_json` as for `start-v1` |
| `initial-output` | returns the retained output of a named VM's create command |
| `copy-in-v1`, `copy-out-v1` | `spore cp`: an `SPCP1` archive on the stdin or stdout stream |
| `spore-build-run-v4`, `spore-build-copy-v5`, `spore-build-workdir-v1` | `spore build` RUN, COPY, and WORKDIR steps |
| `spore-rootfs-grow-v1`, `fsfreeze-v1`, `fsthaw-v1` | rootfs growth and checkpoint quiescing |

The agent has one client at a time: each valid request detaches the previous
client, and a running session keeps going. A `start-v1` with the running
session's id attaches to it. With another id, and without `tty` or
`memory_pressure`, it runs as a transient exec beside the session; like a
build RUN, it holds off later requests until it ends. Once the session has
exited, the next `start-v1` replaces it.

Saved RAM carries the agent that was running, so a restored spore keeps that
agent. Changing what a request or frame means therefore needs a spore manifest
version bump. The test `host request limits match the guest agent` in
`src/build/exec.zig` checks the agent's request, frame payload, and retained
output limits against the host's.

## Sources

`agent.c` holds `main`, the event loop, and request dispatch; `agent.h`
declares what the other files share. Each other file owns one concern:

| File | Concern |
| --- | --- |
| `boot.c` | pseudo filesystems, kernel cmdline flags, build context and input disks |
| `rootfs.c` | rootfs mount, injected files, ext4 growth, freeze/thaw |
| `network.c` | static guest network and the build-mode `resolv.conf` bind |
| `generation.c` | generation device, fan-out identity files, resume entropy and clock |
| `request.c` | the strict request parser |
| `spio.c` | SPIO frames to the attached client |
| `session.c` | starting a command: stdio, PTY, cgroup, exec path lookup, reaping |
| `session_io.c` | a running session's streams, attach, exit, and transient execs |
| `detached.c` | detached starts and retained output |
| `copy.c` | `spore cp` copy-in and copy-out archives |
| `build_run.c` | build RUN mounts, descendant cleanup, and WORKDIR |
| `build_copy.c` | the confined resolver and apply engine for build COPY |
| `build_run_sandbox.c` | the build RUN supervisor's namespaces and seccomp |
| `util.c` | small fd, file, clock, and little-endian helpers |

Test and fuzz entry points sit at the end of the file whose code they reach,
under `SPORE_AGENT_REQUEST_FUZZ`, which only the host unit tests define.

The default embedded initrd also carries a minimal Toybox build for `/bin/sh`
and basic applets such as `echo`, `cat`, `env`, `printf`, `pwd`, `test`,
`uname`, `ls`, `mkdir`, `rm`, `touch`, and `sleep`. `toybox-sh.c` is a small
compatibility wrapper for SporeVM's `/bin/sh -lc` shell-command argv. It maps
that to Toybox `sh -c` without changing the guest agent's exact-argv
`execve(argv[0], ...)` behavior.

`true.c` and `false.c` provide `/bin/true` and `/bin/false`. The helper
binaries the VM smoke scripts run live in `../smoke-helpers` and are added only
to `zig build -Dsmoke-helpers` test builds.

Keep this directory source-only. `scripts/kernel/make-minimal-exec-initrd.sh` owns
compiling these files, building the pinned Toybox source dependency into a
static binary for the selected `aarch64` or `x86_64` Linux guest, and packing
the initrd. The build supplies the generation-device GPA from the selected Zig
board definition, so the guest agent does not carry an architecture-specific
handwritten address.
