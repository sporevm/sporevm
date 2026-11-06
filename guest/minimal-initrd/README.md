# Minimal Exec Initrd

These sources build the small SporeVM guest control plane embedded into the
`spore` binary.

The agent runs as `/init`, listens for the host's run request over vsock,
mounts an optional rootfs read-only or read-write based on the kernel cmdline,
executes the requested argv, and streams stdout, stderr, and exit status frames
back to the host. `start-v1` and `attach-v1` requests use the binary SPIO frame
envelope and can forward pipe-style stdin or allocate/reattach to a guest PTY.
PTY mode mounts devpts, gives the child a controlling terminal, streams terminal
bytes on SPIO stream 4, and applies resize frames with `TIOCSWINSZ`.

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
