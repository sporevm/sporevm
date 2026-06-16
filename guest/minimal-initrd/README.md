# Minimal Exec Initrd

These sources build the small SporeVM guest control plane installed as
`share/sporevm/minimal-exec-initrd.cpio`.

The `agent.c` binary runs as `/init`, listens for the host's run request over
vsock, mounts an optional read-only rootfs, executes the requested argv, and
streams stdout, stderr, and exit status frames back to the host. The other
programs are fixed helper binaries used by product and lifecycle smokes.

Keep this directory source-only. `scripts/make-minimal-exec-initrd.sh` owns
compiling these files into static aarch64 binaries and packing the initrd.
