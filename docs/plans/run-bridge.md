---
status: proposed
last_reviewed: 2026-06-14
spec_refs:
  - docs/plans/foundation.md
  - docs/rootfs.md
  - README.md
  - src/run.zig
  - src/rootfs.zig
  - scripts/make-minimal-exec-initrd.sh
  - scripts/ensure-managed-kernel.sh
related_plans:
  - docs/plans/foundation.md
---

# Spore Run Bridge Plan

## Summary

`spore run` is the product bridge between the low-level VMM foundation and a
user-visible "run a command" experience. It should stay narrower than a full
container runtime: boot a supported aarch64 Linux guest, send one explicit argv
request over vsock, return bounded stdout/stderr and the command status, and
fail closed when required boot assets or workload inputs are unsupported.

The current implementation proves the host/guest control path with explicit
local kernel and initrd paths. This plan makes that primitive useful in stages:
first remove manual boot-asset setup, then attach a read-only rootfs disk and
exec from it, then connect the existing OCI-to-ext4 builder to `run`.

The first OCI-capable milestone is intentionally two-step:

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

Direct image references come later through an explicit flag:

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

This keeps `spore run -- /bin/writeout` unambiguous, avoids smuggling OCI
runtime semantics into the first rootfs slice, and preserves the foundation
plan boundary that consumers own image policy.

## Problem

The current `spore run` command is useful for proving the VMM path, but it is
awkward as a product surface:

- users must manually resolve a managed kernel path;
- users must manually build and pass the minimal exec initrd;
- only binaries packed into that initrd can run;
- there is no way for `run` to attach a rootfs disk even though the boot
  harnesses and backends already support virtio-blk;
- `spore rootfs build` can materialize an OCI image into ext4, but that output
  is not yet consumable by `spore run`.

Without a run bridge plan, it is easy to overcorrect in either direction:
spend too long polishing the toy initrd path, or jump straight to broad OCI
runtime semantics that the foundation plan says SporeVM should not own.

## Goals

- Make the minimal run path ergonomic enough to test directly:

  ```console
  spore run -- /bin/writeout
  ```

- Keep explicit override paths for kernel and initrd so smoke tests,
  experiments, and cleanroom can control boot assets.
- Add rootfs disk execution without changing the frozen device model.
- Make the first rootfs execution mode read-only and explicit.
- Connect OCI to `run` first through the existing deterministic ext4 builder.
- Keep direct OCI image support as cache/build orchestration, not a full OCI
  runtime contract.
- Keep all asset setup messages on stderr so `--json` remains machine-readable
  on stdout.

## Non-Goals

- No OCI Entrypoint/Cmd/User/Env/Workdir behavior in the first rootfs slices.
- No implicit shell wrapping. `spore run --rootfs alpine.ext4 -- echo hi` means
  exec `echo`; it does not search shells or rewrite argv.
- No writable cached OCI rootfs in the first rootfs slices.
- No network, secret, workspace, mount, or package-manager policy.
- No bundle-aware `spore run` in this track. Spore bundles are for packed
  spores and fan-out distribution, not initial workload image input.
- No disk capture in the spore manifest as part of the run bridge. v0 disk
  restore continues to require the same backing disk out of band until the
  foundation plan adds disk manifests.

## Current State

- `src/run.zig` accepts optional `--kernel`, optional `--initrd`, and one argv
  request. When omitted, the CLI resolves default run assets before boot.
- Backend selection already defaults to `auto`, resolving to HVF on Darwin
  arm64 and KVM on Linux/aarch64.
- `scripts/ensure-managed-kernel.sh initrd` resolves, downloads, verifies, and
  caches the managed cleanroom-kernels initrd-profile kernel.
- `scripts/make-minimal-exec-initrd.sh` builds a tiny initrd with the guest
  exec agent and fixed helper binaries.
- `zig build` installs that minimal exec initrd at
  `share/sporevm/minimal-exec-initrd.cpio`.
- The run output slice adds bounded stdout/stderr to the exit frame.
- `hvf-boot`, `kvm-boot`, `hvf.vm`, and `kvm.vm` already support an optional
  disk fd backed by virtio-blk.
- `spore rootfs build` already materializes OCI images into deterministic ext4
  images and records metadata.

## Target Model

### Minimal Initrd Run

```console
spore run -- /bin/writeout
spore run --json -- /bin/writeout
spore run --kernel Image --initrd minimal.cpio -- /bin/writeout
```

When kernel or initrd are omitted, `run` resolves default run assets:

- kernel: managed initrd-profile aarch64 kernel, honoring
  `SPOREVM_KERNEL_IMAGE` as the explicit local override;
- initrd: the installed minimal exec initrd, with `SPOREVM_RUN_INITRD` as the
  explicit local override.

The default initrd is a developer/product bridge, not the future rootfs.
Commands only work if they are present inside the initrd.

### Rootfs Run

```console
spore run --rootfs rootfs.ext4 -- /bin/echo hi
spore run --kernel Image --initrd minimal.cpio --rootfs rootfs.ext4 -- /bin/echo hi
```

The host attaches the rootfs ext4 image as virtio-blk. The initrd agent mounts
it read-only, sets up the minimum guest runtime required to exec an explicit
argv from that filesystem, and returns the same stdout/stderr/status frame.

The first rootfs version runs as root with a closed env, unless the current
`run` contract has already gained explicit env support by then. OCI user,
working directory, entrypoint, cmd, and env are later image-policy work.

### OCI Rootfs Build And Run

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

This is the first point where SporeVM can take an OCI image and run something
from it. The image is not consumed directly by the VMM. It is first
materialized into an ext4 rootfs by the existing builder, then attached as a
block device.

### Direct Image Convenience

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

Direct image mode resolves or builds a cached rootfs image, then delegates to
the same `--rootfs` path. The cache key must include at least the resolved
image digest, platform, rootfs builder version or format version, and any
material build options. Mutable tags are resolved before cache lookup records
the reusable identity.

Direct image mode remains explicit through `--image`; the first positional
argument is not overloaded as an image reference.

## Safety And Invariants

- `--json` writes exactly one machine-readable result frame to stdout; asset
  resolution, downloads, and cache messages go to stderr.
- Missing default assets fail before booting a VM.
- Default asset cache writes use temporary files plus atomic rename.
- Downloaded kernels are verified before use.
- Cached OCI rootfs images are never mounted writable by default.
- Unsupported backends fail closed before asset setup when possible.
- Rootfs execution does not widen the device model. It uses the existing
  virtio-blk device.
- Rootfs inputs are workload inputs, not spore manifest state, until disk
  manifests land in the foundation plan.
- The initrd agent treats host requests and rootfs contents as untrusted input.
  New parsers or binary protocols require tests, and attacker-influenced
  parsers follow the repository security guidance.

## Interaction With The Foundation Plan

This plan does not replace the foundation slices. It is a bridge track layered
over already-landed foundation capabilities:

- Slice 1/2 provide boot, initrd, virtio-blk, and vsock on KVM/HVF.
- The current `spore run` bridge proves one-shot boot/exec/status over vsock.
- Rootfs execution uses existing virtio-blk support; it does not add a device.
- The OCI rootfs builder is an offline utility by design and remains outside
  the VMM monitor.
- Slice 5/6 RAM economics and spore distribution remain the release-critical
  foundation path. Direct OCI image input is not the same thing as publishing
  or distributing spores.

The bridge starts mattering to the foundation plan again when disk-backed
workloads must suspend, fork, and resume portably. That is where disk manifests,
rootfs identity, and cache policy need a foundation-level decision.

## Delivery Strategy

### Slice A: Default Run Assets

Status: implemented.

Scope:

- Make `--kernel` and `--initrd` optional for `spore run`.
- Add a default run-asset resolver used only by the CLI path, not the spore
  manifest format.
- Install or otherwise make the minimal exec initrd discoverable from a normal
  `zig build` output.
- Keep explicit `--kernel` and `--initrd` overrides.
- Keep `SPOREVM_KERNEL_IMAGE`; add `SPOREVM_RUN_INITRD`.

Done when:

```console
mise run build
zig-out/bin/spore run -- /bin/writeout
zig-out/bin/spore run --json -- /bin/writeout
zig-out/bin/spore run --kernel Image --initrd minimal.cpio -- /bin/writeout
```

work on a supported local backend, with setup noise on stderr and command
output/result semantics unchanged.

### Slice B: Read-Only Rootfs Attach And Exec

Scope:

- Add `--rootfs PATH` to `spore run`.
- Open the rootfs image read-only on the host and attach it as virtio-blk.
- Extend the minimal initrd agent to mount the block device read-only.
- Exec explicit argv inside the mounted rootfs via `chroot` or an equivalent
  simple root switch.
- Keep closed env and root user unless explicit env/user support has landed.

Done when:

```console
spore run --rootfs rootfs.ext4 -- /bin/echo hi
spore run --rootfs rootfs.ext4 -- /bin/false
spore run --json --rootfs rootfs.ext4 -- /bin/echo hi
```

prove stdout/stderr/status propagation from binaries that live in the rootfs.

### Slice C: OCI Two-Step Smoke

Scope:

- Document and validate the two-step OCI path using the existing rootfs
  builder.
- Add a smoke script or test fixture that builds a small linux/arm64 rootfs
  and runs an explicit argv from it on supported hardware.
- Require digest metadata in the smoke output so tag-based runs can be traced
  back to a resolved image identity.

Done when:

```console
spore rootfs build docker.io/library/alpine:3.20 --platform linux/arm64 --output alpine.ext4
spore run --rootfs alpine.ext4 -- /bin/echo hi
```

is the documented first OCI-capable workflow.

### Slice D: Direct Image Cache

Scope:

- Add `--image REF` as sugar over `rootfs build` plus `--rootfs`.
- Resolve tags before choosing a cache entry.
- Cache rootfs ext4 outputs by resolved image digest, platform, and builder
  identity.
- Keep the default rootfs mounted read-only.
- Keep `--rootfs` as the lower-level escape hatch.

Done when:

```console
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

builds or reuses a cached rootfs and then exercises the same rootfs execution
path as Slice B.

### Slice E: Runtime Metadata And Writable State

Scope:

- Add only the OCI runtime metadata that SporeVM intentionally owns, if any.
- Consider explicit `--env`, `--workdir`, and `--user` flags before honoring
  image defaults implicitly.
- Add an ephemeral writable layer or scratch disk before supporting workloads
  that need mutable root state.

This is deliberately later because it crosses from VMM bridge into workload
policy.

## Verification

- Unit tests for run argument parsing and default asset resolution.
- Unit tests for cache key construction and atomic cache writes.
- Shell syntax and build checks for any generated initrd helpers.
- HVF smoke for default initrd run on Apple Silicon.
- KVM smoke for default initrd run on Linux/aarch64.
- HVF and KVM smokes for `--rootfs` once rootfs execution lands.
- OCI two-step smoke using a small linux/arm64 image.
- Negative tests:
  - missing default assets;
  - unsupported host/backend;
  - corrupt or architecture-mismatched rootfs metadata when metadata is
    available;
  - rootfs command not found;
  - `--json` with asset setup messages present only on stderr.

## Resolved Decisions

- The first next slice is default run assets, not rootfs.
- The first OCI-capable milestone is two-step `rootfs build` plus
  `run --rootfs`.
- Direct OCI input uses `--image REF`, not a positional image argument.
- Rootfs execution starts read-only to avoid mutating cached image state.
- OCI Entrypoint/Cmd/User/Env/Workdir are deferred.
- Bundle-aware run semantics are outside this bridge track.

## Open Questions And Recommended Defaults

### Resolved Slice A Defaults

- Managed kernel resolver: start by reusing the existing
  `scripts/ensure-managed-kernel.sh` behavior for the worktree/dev build, but
  keep the dependency explicit and fail with a clear error if the helper is not
  available. Do not present this as a packaged single-binary behavior until the
  resolver is moved into Zig or installed as a supported helper.
- Minimal exec initrd: prefer a build-installed artifact over first-use
  generation. `zig build` should leave the default initrd somewhere `spore run`
  can locate from `zig-out/bin/spore`, while `SPOREVM_RUN_INITRD` remains the
  override.

### Blocking Slice B

- Kernel profile: the managed `v0.3.0` cleanroom-kernels assets split the
  required capabilities. The `initrd` and `sporevm` profiles have
  `CONFIG_BLK_DEV_INITRD=y` but do not expose virtio-blk/ext4 in the smoke;
  the `rootfs` profile has `CONFIG_VIRTIO_BLK=y` and `CONFIG_EXT4_FS=y` but no
  `CONFIG_BLK_DEV_INITRD`, so it panics before the initrd agent can run. Slice
  B needs a combined run-rootfs kernel profile before the SporeVM `--rootfs`
  CLI should be exposed.
- Rootfs device discovery: prefer mounting `devtmpfs` in the agent and waiting
  for the virtio-blk device node. A fixed `/dev/vda` mknod is acceptable only
  as a temporary smoke fallback if devtmpfs support is missing from the managed
  kernel.

### Safe To Defer

- Direct image refs: start with digest-pinned refs if cache provenance is still
  unclear when Slice D begins. Mutable tags are acceptable only after the cache
  key records the resolved digest and metadata path.

## Key Learnings From Pressure-Testing

The riskiest scope trap is making direct OCI input the first slice. That would
mix command execution, image resolution, cache invalidation, rootfs mutability,
and runtime metadata before the lower-level rootfs attach path is proven. The
plan therefore starts with default run assets, then read-only `--rootfs`, then
the existing rootfs builder.

The second risk is cache poisoning through writable rootfs mounts. A cached OCI
rootfs must not be mutated by `spore run`, so rootfs execution starts read-only
and writable state is deferred until there is an explicit scratch or overlay
model.

The third risk is a misleading product claim around OCI runtime semantics.
Running an explicit argv from an OCI-derived filesystem is not the same as
implementing Docker semantics. The plan records that boundary and keeps image
metadata behavior in a later slice.

The fourth risk is default asset resolution that only works from a source tree.
The first slice must either make the helper dependency explicitly
development-only or install/generate assets in a way that survives normal
`zig build` output and later package installation.
