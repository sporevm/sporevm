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

v0 spores do not capture arbitrary disk bytes yet. Product resume can reattach
verified immutable rootfs artifacts from the local content cache; writable or
unknown disk state still requires an explicit future disk contract.

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
- run one explicit argv request from a completed base spore with `spore run --from`;
- stream fresh run stdout/stderr and exit with the guest command status;
- capture a `spore run` on command exit or on a host signal with `--capture`;
- mint metadata-only child spores with `spore fork`;
- resume forked child directories with prefixed output using `spore fanout`;
- resume one diskless or verified immutable-rootfs spore with `spore resume`;
- pack and unpack local chunkpack bundles with `spore pack` / `spore unpack`;
- build deterministic ext4 rootfs images from OCI images with
  `spore rootfs build`;
- run from an explicit read-only rootfs with `spore run --rootfs`;
- build or reuse a cached rootfs directly from an OCI ref with
  `spore run --image`;
- create, exec, list, and remove named VMs through one per-VM monitor process;
- suspend a diskless named VM and resume it under a new name on local HVF.

Named lifecycle monitor mode is currently local-HVF only. KVM monitor wake
support and disk-backed lifecycle suspend/resume remain follow-up work. The
backend smoke harnesses still exercise lower-level capture paths directly.

Current active work is concentrated in three places: always-on dirty tracking and
distribution scale in the foundation plan, remote preparation for immutable
rootfs artifacts, and named lifecycle speed/KVM parity.

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
mise run install
mise run smoke:run
mise run smoke:run-capture
mise run smoke:counter-fanout
mise run smoke:rootfs-fanout
```

`mise run check` runs unit tests, the product build, and diff hygiene.
`mise run install` builds an optimized `spore` and installs it into `~/bin`,
with runtime assets under `~/share/sporevm`.
`mise run smoke` builds once, then runs product run and run-capture/resume
smokes. `smoke:counter-fanout` and `smoke:rootfs-fanout` are opt-in demo smokes;
the rootfs fan-out smoke builds a published Ruby OCI image and runs forked
children with `spore run --from` in parallel.

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
initrd installed by `zig build` or `mise run install`. The managed kernel is
downloaded and SHA256-verified by `spore` itself, then cached under the
platform cache directory. Override the boot assets with `--kernel` and
`--initrd`, or set `SPOREVM_KERNEL_IMAGE` and `SPOREVM_RUN_INITRD`.

Pass `--debug` before the command, for example `spore --debug run ...`, to show
verbose VMM setup and restore logs.

The minimal agent streams command stdout and stderr over a small framed vsock
protocol. The host forwards those streams and exits with the guest command
status.

Run one command from a completed base spore:

```bash
zig-out/bin/spore run --from /tmp/run.spore -- /bin/writeout
```

`--from` resumes the spore, attaches any verified immutable rootfs artifact
recorded in the manifest, sends the argv after `--` to the restored exec agent,
streams stdout/stderr, and exits with the command status. It is mutually
exclusive with fresh boot inputs such as `--kernel`, `--initrd`, `--rootfs`, and
`--image`; the RAM size comes from the spore manifest. The restored guest must be
able to accept a fresh exec session. Signal-captured running workloads remain a
`spore resume`, `spore fork`, or `spore fanout` path until the guest-agent
protocol can reconnect to or multiplex active commands.

Keep one named VM alive and run more than one command in it:

```bash
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore create bench-1
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore exec bench-1 -- /bin/writeout
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore exec bench-1 -- /bin/true
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore rm bench-1
```

The lifecycle registry lives under `SPOREVM_RUNTIME_DIR`, then
`$XDG_RUNTIME_DIR/sporevm`, then a private temp fallback. Names are explicit and
restricted to a conservative path-safe set. `spore create --image` and
`spore create --rootfs` reuse the same read-only rootfs path as `spore run`.

Checkpoint a diskless named VM and resume it under a new name:

```bash
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore create snap-1
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore exec snap-1 -- /bin/true
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore suspend snap-1 --out /tmp/snap.spore
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore resume /tmp/snap.spore --name snap-2
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore exec snap-2 -- /bin/writeout
SPOREVM_RUNTIME_DIR=/tmp/sporevm-demo zig-out/bin/spore rm snap-2
```

Capture a run on command exit or on a host signal:

```bash
zig-out/bin/spore run \
  --capture /tmp/run.spore \
  --capture-on USR1 \
  -- /bin/sleeper &
run_pid=$!

kill -USR1 "$run_pid"
wait "$run_pid"
zig-out/bin/spore resume /tmp/run.spore
```

With plain `--capture DIR`, `spore run` captures after the guest command exits
and returns the guest status. With `--capture-on USR1` or another host signal,
the first matching signal writes a spore and exits zero; a second matching
signal exits 130. Add `--continue-after-capture` to keep the original run alive
after a signal-triggered snapshot.

Fork an existing spore:

```bash
zig-out/bin/spore fork /tmp/run.spore --count 100 --out /tmp/forks
```

Children are named `000000`, `000001`, and so on, and share the parent's chunk
store.

Resume forked children concurrently with prefixed output:

```bash
zig-out/bin/spore fanout /tmp/forks --parallel --for 20s
```

See [docs/fanout.md](docs/fanout.md) for the local child identity contract.

Resume one captured or forked spore:

```bash
zig-out/bin/spore resume /tmp/forks/000000
```

Product resume streams the restored guest console and defaults RAM size from
the spore manifest. Spores captured from `spore run --image` record the
immutable rootfs content digest and resume by reopening the verified
content-addressed cache entry. Arbitrary writable disk restore is still
unsupported.

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

For local Docker buildx output without a registry push, import an OCI layout
with `spore rootfs import-oci ... --ref local/name:tag`, then run with
`spore run --image local/name:tag`.

`--image` still runs the explicit argv after `--`. It does not apply OCI
Entrypoint, Cmd, User, Env, or Workdir yet. Set `SPOREVM_ROOTFS_CACHE_DIR` to
override the cache directory.

When combined with `--capture`, `--image` records immutable rootfs
identity in the spore manifest. `spore resume` later verifies the cached rootfs
bytes by digest before attaching the fd read-only. `--rootfs PATH` still works
for ordinary runs, but `--rootfs PATH --capture` is rejected until there is an
import/preload command that can record portable rootfs identity.

Exercise the rootfs capture/fork/resume path with:

```bash
mise run smoke:rootfs-fanout
```

See [docs/rootfs.md](docs/rootfs.md) for tag resolution, metadata, and ext4
tooling details.

## Advanced Validation

Most local validation should use `mise run smoke`. Extra product-shaped checks
are available when a change touches fan-out or rootfs behavior:

- `mise run smoke:counter-fanout`: exercise diskless capture, fork, and
  parallel product resume fan-out.
- `mise run smoke:rootfs-fanout`: exercise OCI rootfs capture, fork, and
  parallel `spore run --from` child execution.
- `scripts/smoke-run-oci-rootfs.sh`: exercise an explicit OCI/rootfs command.

`scripts/benchmark-kvm-dirty-tracking.sh` remains the lower-level measurement
path for KVM dirty-log and HVF write-protect tracking until those metrics are
available through product or lifecycle capture paths. It uses the backend boot
harnesses from `zig build hvf-boot` / `zig build kvm-boot`.

`zig build hvf-gic-probe` remains as a host capability probe for
Hypervisor.framework GIC state. New validation should be product-shaped unless
it proves or measures a backend capability that cannot be reached through the
CLI.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
