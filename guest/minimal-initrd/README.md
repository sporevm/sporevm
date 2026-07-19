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
`TIOCSWINSZ`. The other programs are fixed helper binaries used by product and
lifecycle smokes.

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

`netcheck.c` verifies the static `spore run --net` guest link setup without
requiring distro networking tools in the initrd.
`nslookup.c` is a tiny smoke helper for the SporeVM-managed DNS proxy; it sends
one A-record query to the configured resolver and prints the first IPv4 answer.
`wget.c` is a narrow HTTP-only smoke helper for outbound TCP proxying; it
supports `-qO-` and streams bounded response bodies to stdout.
`httpd.c` is a one-shot HTTP responder for host-to-guest TCP forwarding smokes.
`flockcheck.c` verifies guest `flock(2)` behavior for runtime paths such as
Docker and containerd metadata databases.
`cgroupcheck.c` verifies the cgroup2 mount behavior Docker expects before daemon
startup.
`gencheck.c` verifies forked `spore run --from` commands start after generation
metadata and resume entropy are visible in `/run/sporevm/env`.
`rngcheck.c` performs a bounded non-zero read from `/dev/hwrng`.
`blkcheck.c` reads all four frozen block slots, verifies root-disk write/readback,
and attempts writes against the three immutable source slots; the host smoke
proves their backends remain byte-for-byte unchanged.

Keep this directory source-only. `scripts/kernel/make-minimal-exec-initrd.sh` owns
compiling these files, building the pinned Toybox source dependency into a
static binary for the selected `aarch64` or `x86_64` Linux guest, and packing
the initrd. The build supplies the generation-device GPA from the selected Zig
board definition, so the guest agent does not carry an architecture-specific
handwritten address.
