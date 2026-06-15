# 🍄 SporeVM

SporeVM is a small aarch64 virtual machine monitor for forkable Linux microVM
checkpoints. The spore is the product: a sealed checkpoint with normalized
machine state, device state, content-addressed memory chunks, and a platform
contract that fails closed when a host cannot restore it honestly.

The first useful shape is warm CI fan-out: start the expensive runtime once,
capture the VM at a quiescent point, then fork children without copying all of
RAM.

The arm64 bet is deliberate. Apple Silicon and AWS Graviton are the useful
overlap; x86 platform archaeology can wait. One Zig codebase targets:

- KVM on Linux/aarch64
- Hypervisor.framework on Apple Silicon macOS

Both backends expose the same fixed guest-visible board: RAM layout, interrupt
wiring, boot contract, virtio-mmio devices, and the SporeVM generation device.
Cross-backend restore is a useful diagnostic; identical-host-class fork/fan-out
is the product path.

v0 spores do not capture disk bytes yet, so disk-backed resume still requires
the same backing disk out of band.

The target lifecycle property is that common operations avoid scaling with RAM
size:

- **Suspend** is a pause plus a small dirty tail flush.
- **Fork** is a metadata write.
- **Resume** is bounded by the working set, not total guest RAM.

## Design Shape

- **One boring board.** Linux sees the same intentionally small aarch64 machine
  on KVM and HVF. Portable here means "restore only when the host satisfies this
  contract", not "run any guest on any machine".
- **Fork is mostly paperwork.** Child spores point at the same verified chunks
  and get their own identity. On same-host paths, a trusted RAM backing can be
  mapped privately so reads share pages and writes diverge.
- **Forked guests know they forked.** The generation device gives the guest a
  small hook for identity, entropy, clock, and shard fixups after resume.

## Status

SporeVM is early, pre-release software. Breaking changes are expected before
1.0. The plan of record is
[docs/plans/foundation.md](docs/plans/foundation.md).

Current `main` can:

- boot the pinned aarch64 Linux kernel on HVF and KVM;
- inspect host platform facts with `spore host-info`;
- summarize a spore manifest with `spore inspect <spore-dir>`;
- run one explicit argv request in a throwaway VM with `spore run`;
- stream fresh run stdout/stderr and exit with the guest command status;
- capture a long-running `spore run` on a host signal with
  `--capture-on-abort`;
- mint metadata-only child spores with `spore fork`;
- resume one diskless spore with `spore resume`;
- pack and unpack local chunkpack bundles with `spore pack` / `spore unpack`;
- build deterministic ext4 rootfs images from OCI images with
  `spore rootfs build`;
- run from an explicit read-only rootfs with `spore run --rootfs`;
- build or reuse a cached rootfs directly from an OCI ref with
  `spore run --image`.

Create and suspend as long-lived product verbs are still planned. The backend
smoke harnesses exercise the lower-level capture path today.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run check
mise run smoke
```

Useful task split:

```bash
mise run test
mise run build
mise run smoke:run
mise run smoke:run-capture
mise run smoke:resume
```

`mise run check` runs unit tests, the product build, and diff hygiene.
`mise run smoke` builds once, then runs product run, run-capture, and resume
smokes.

`zig build` installs the minimal exec initrd used by `spore run`, so `cpio`
must be available in `PATH`.

KVM work needs an aarch64 Linux host with KVM. Hypervisor.framework work needs
an Apple Silicon Mac on macOS 15 or newer.

## Product CLI

Run one command in a throwaway VM:

```bash
zig-out/bin/spore run -- /bin/writeout
```

`spore run` defaults to the managed SporeVM run kernel and the minimal exec
initrd installed by `zig build`. Override the boot assets with `--kernel` and
`--initrd`, or set `SPOREVM_KERNEL_IMAGE` and `SPOREVM_RUN_INITRD`.

The minimal agent streams command stdout and stderr over a small framed vsock
protocol. The host forwards those streams and exits with the guest command
status.

Capture a long-running run on a host signal:

```bash
zig-out/bin/spore run \
  --capture-on-abort /tmp/run.spore \
  --capture-signal USR1 \
  -- /bin/sleeper &
run_pid=$!

kill -USR1 "$run_pid"
wait "$run_pid"
zig-out/bin/spore resume /tmp/run.spore
```

With `--capture-on-abort`, the first matching host signal writes a spore and
exits zero; a second Ctrl-C exits 130. If the guest command finishes first,
`spore run` still exits with the guest status.

Fork an existing spore:

```bash
zig-out/bin/spore fork /tmp/run.spore --count 100 --out /tmp/forks
```

Children are named `000000`, `000001`, and so on, and share the parent's chunk
store.

Resume one captured or forked diskless spore:

```bash
zig-out/bin/spore resume /tmp/forks/000000
```

Product resume streams the restored guest console and defaults RAM size from
the spore manifest. Disk-backed restore still needs the backend harness plus
the original backing disk.

Pack and unpack a spore:

```bash
zig-out/bin/spore pack /tmp/run.spore --out /tmp/run.bundle
zig-out/bin/spore unpack /tmp/run.bundle --out /tmp/run.unpacked
```

Both commands report a `bundle_digest` for cache identity.

## Rootfs Images

Build a deterministic ext4 rootfs from an OCI image:

```bash
zig-out/bin/spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4
```

Run from that rootfs read-only:

```bash
zig-out/bin/spore run --rootfs alpine.ext4 -- /bin/echo hi
```

Or let `spore run` build and reuse a cached rootfs from an OCI reference:

```bash
zig-out/bin/spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

`--image` still runs the explicit argv after `--`. It does not apply OCI
Entrypoint, Cmd, User, Env, or Workdir yet. Set `SPOREVM_ROOTFS_CACHE_DIR` to
override the cache directory.

See [docs/rootfs.md](docs/rootfs.md) for tag resolution, metadata, and ext4
tooling details.

## Advanced Validation

Most local validation should use `mise run smoke`. Lower-level tools remain for
backend debugging and hardware proof work:

- `zig build hvf-boot` / `zig build kvm-boot`: build backend boot and capture
  harnesses.
- `zig build hvf-gic-probe`: probe Hypervisor.framework GIC state support.
- `scripts/smoke-restore-leg.sh`: split capture/resume legs for backend
  debugging.
- `scripts/smoke-fork-fanout.sh`: exercise fork generation fixups.
- `scripts/smoke-remote-bundle.sh`: run SSM/S3 cross-host bundle validation.

Run the relevant script with `--help` before using it; these are intentionally
more harness-shaped than product-shaped.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
