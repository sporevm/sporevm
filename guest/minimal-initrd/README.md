# Minimal Exec Initrd

These sources build the small SporeVM guest control plane embedded into the
`spore` binary.

The `agent.c` binary runs as `/init`, listens for the host's run request over
vsock, mounts an optional rootfs read-only or read-write based on the kernel
cmdline, executes the requested argv, and streams stdout, stderr, and exit
status frames back to the host. `start-v1` and `attach-v1` requests use the
binary SPIO frame envelope and can forward pipe-style stdin or allocate/reattach
to a guest PTY. PTY mode mounts devpts, gives the child a controlling terminal,
streams terminal bytes on SPIO stream 4, and applies resize frames with
`TIOCSWINSZ`.

Build COPY request decoding and SPIO dispatch remain in `agent.c`.
`build_copy.c` owns the confined source/destination resolver and filesystem
application engine used by COPY, including metadata, hardlink, and xattr
handling.

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
