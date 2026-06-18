# Minimal Exec Initrd

These sources build the small SporeVM guest control plane installed as
`share/sporevm/minimal-exec-initrd.cpio`.

The `agent.c` binary runs as `/init`, listens for the host's run request over
vsock, mounts an optional read-only rootfs, executes the requested argv, and
streams stdout, stderr, and exit status frames back to the host. The other
programs are fixed helper binaries used by product and lifecycle smokes.
`netcheck.c` verifies the static `spore run --net` guest link setup without
requiring distro networking tools in the initrd.
`nslookup.c` is a tiny smoke helper for the SporeVM-managed DNS proxy; it sends
one A-record query to the configured resolver and prints the first IPv4 answer.
`wget.c` is a narrow HTTP-only smoke helper for outbound TCP proxying; it
supports `-qO-` and streams bounded response bodies to stdout.

Keep this directory source-only. `scripts/make-minimal-exec-initrd.sh` owns
compiling these files into static aarch64 binaries and packing the initrd.
