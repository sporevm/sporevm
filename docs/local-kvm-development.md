# Local KVM development on Apple Silicon

Apple Silicon developers can run SporeVM's Linux/KVM backend locally by nesting
it inside an emulated Arm Linux host. QEMU's TCG accelerator emulates Arm EL2,
Alpine exposes that as `/dev/kvm`, and SporeVM uses the nested KVM interface
normally. The result is slower than native KVM, but a warm outer guest makes
ordinary build-run-debug loops much faster than waiting for a remote Linux host.

This is an emulated development path, not a replacement for the native KVM and
Hypervisor.framework release gates. It is useful for backend-neutral work,
Linux/KVM lifecycle tests, save and restore, and virtio networking.

## Prerequisites

The harness currently supports Apple Silicon macOS. Install QEMU and the normal
SporeVM toolchain:

```console
brew install qemu
mise install
```

macOS already supplies the other harness dependencies: `expect`, `nc`, `ssh`,
and `ssh-keygen`.

## Start a development guest

Build SporeVM for static Arm Linux and start the outer guest:

```console
mise run dev:qemu-kvm-build
mise run dev:qemu-kvm-start
```

The first start downloads the pinned Alpine virt ISO and verifies its SHA-256.
Later starts reuse it. The live guest installs its SSH server during bootstrap,
so the outer guest needs internet access on every cold start. QEMU stays running
until explicitly stopped, and the repository is mounted read-only at
`/workspace` with 9P. A rebuild therefore replaces the binary seen by the
running guest without rebooting it:

```console
mise run dev:qemu-kvm-build
scripts/dev/qemu-tcg-kvm.sh spore run -- /bin/writeout
```

Use `scripts/dev/qemu-tcg-kvm.sh shell` for an interactive Alpine shell and
`scripts/dev/qemu-tcg-kvm.sh status` to verify the process, `/dev/kvm`, and
SporeVM binary.

## Run the smoke suite

```console
mise run dev:qemu-kvm-smoke
```

The suite exercises a fresh KVM boot, guest network configuration, restricted
egress, the link-local hard floor, save and restore, and host-to-guest port
forwarding. It intentionally uses `detectportal.firefox.com` for positive
restricted-egress coverage because QEMU's DNS proxy can map documentation-only
domains such as `example.com` to loopback, which SporeVM correctly rejects.

Stop the warm guest when it is no longer needed:

```console
mise run dev:qemu-kvm-stop
```

## State and configuration

Cross-build output lives in `zig-out/qemu-tcg`, while the PID, sockets, and
generated SSH key live in `zig-out/qemu-tcg-state`. Both are ignored build
artifacts. The Alpine ISO is cached under
`${XDG_CACHE_HOME:-$HOME/.cache}/sporevm/qemu-tcg`.
The latest cold-boot transcript is retained at
`zig-out/qemu-tcg-state/boot.log` for bootstrap debugging.

The most useful overrides are:

- `SPOREVM_TCG_SSH_PORT` changes the host SSH port from `22022`.
- `SPOREVM_TCG_CPUS` and `SPOREVM_TCG_MEMORY` size the outer guest.
- `SPOREVM_TCG_FIRMWARE` selects a non-Homebrew EDK2 firmware image.
- `SPOREVM_TCG_CACHE_DIR` relocates the Alpine ISO cache.

Use the same SSH-port override for every command while a guest is running. The
guest bootstrap explicitly brings up both `lo` and `eth0`, acquires a DHCP
lease, and mounts the repository. If SporeVM reports DNS failures or its
port-forwarding network helper never becomes ready, check those interfaces
inside `scripts/dev/qemu-tcg-kvm.sh shell` before debugging SporeVM itself.
