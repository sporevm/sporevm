---
status: active
last_reviewed: 2026-07-04
spec_refs:
  - README.md
  - docs/lifecycle.md
  - SECURITY.md
  - build.zig
  - build.zig.zon
  - src/run.zig
  - scripts/make-minimal-exec-initrd.sh
  - scripts/smoke-run.sh
  - guest/minimal-initrd/README.md
  - guest/minimal-initrd/agent.c
related_plans:
  - docs/plans/interactive-input-tty.md
  - docs/plans/named-lifecycle-contract-hardening.md
---

# Default Toybox Initrd Shell

## Summary

The embedded minimal initrd should grow from a SporeVM helper-only environment
into a small, pinned shell environment suitable for basic `spore run` command
usage. A default run like this should work without an OCI image:

```bash
spore run 'echo hi'
spore run -- /bin/echo hi
```

Toybox is the right default for this slice because it gives one static binary
for a bounded set of common applets. SporeVM keeps its existing guest agent and
product smoke helpers; Toybox supplies only the default shell and basic command
surface that users already expect from the documented shell-command form.

This is not a move toward a distro initrd. The default initrd remains a SporeVM
control plane with a small command environment. Full distro behavior,
package-manager workflows, user accounts, and richer filesystem layout remain
the job of `--image`, `--rootfs`, or a caller-provided `--initrd`.

## Problem

`spore run` accepts shell-command form and wraps it as:

```text
/bin/sh -lc <command>
```

That works with OCI rootfs environments such as Alpine, but the embedded
minimal initrd currently has no `/bin/sh` and no `/bin/echo`. The result is a
VM that boots successfully, reaches ready, and then exits 127 for commands that
look like the documented default CLI shape.

The current diagnostic points users toward `--image`, `--rootfs`, or a
command-capable initrd. That is correct for unsupported commands, but it makes
the default command path feel broken for the smallest possible smoke command.

## Goals

- Make the embedded initrd support basic shell-command form by default.
- Support exact argv for a bounded set of basic absolute paths, including
  `/bin/sh`, `/bin/echo`, `/bin/cat`, `/bin/env`, `/bin/printf`, `/bin/pwd`,
  `/bin/test`, `/bin/uname`, `/bin/ls`, `/bin/mkdir`, `/bin/rm`, `/bin/touch`,
  and `/bin/sleep`.
- Preserve the current no-PATH-lookup exact argv contract. `spore run -- echo`
  remains `execve("echo", ...)` and should fail unless the guest environment
  itself implements that path.
- Keep existing SporeVM helper binaries authoritative when their names overlap
  with Toybox applets.
- Pin Toybox source and build it reproducibly through the repo build.
- Update docs and smokes so the default behavior and its limits are explicit.

## Non-Goals

- No distro compatibility claim for the embedded initrd.
- No package manager, `/usr` layout, login stack, PAM, users/groups database, or
  service manager in the default initrd.
- No broad Toybox `defconfig` in the shipped initrd.
- No network applet expansion from Toybox in the first slice. Existing SporeVM
  `nslookup`, `wget`, and `httpd` smoke helpers stay separate.
- No permanent public CLI flag for choosing between helper-only and Toybox
  initrds. `--initrd` is already the explicit escape hatch.
- No host-side PATH lookup for guest exact argv.

## Target Model

The default embedded initrd contains:

- `/init`: the existing SporeVM guest agent;
- existing SporeVM helper binaries such as `/bin/writeout`, `/bin/netcheck`,
  `/bin/wget`, `/bin/httpd`, `/bin/flockcheck`, and `/bin/cgroupcheck`;
- `/bin/toybox`: a static aarch64 Linux Toybox binary built from a pinned
  source dependency;
- `/bin/sh`: a tiny compatibility wrapper that maps SporeVM's current `-lc`
  shell argv to Toybox `sh -c`;
- explicit applet symlinks for the first supported command set.

Shell-form command behavior:

```bash
spore run 'echo hi'
```

The host still sends `/bin/sh -lc "echo hi"`. Inside the default initrd,
`/bin/sh` strips the unsupported login-shell flag and execs Toybox as:

```text
/bin/toybox sh -c "echo hi"
```

Exact argv behavior:

```bash
spore run -- /bin/echo hi
```

The guest agent still calls `execve(argv[0], ...)` directly. Absolute paths that
exist in the initrd run. Bare command names do not gain implicit PATH lookup.

Unsupported command behavior:

```bash
spore run -- /bin/not-there
```

Missing commands still exit 127 with an actionable initrd/rootfs hint.

## Build And Supply Chain Model

Toybox should be pinned as source, not checked in as a binary. The preferred
shape is a `build.zig.zon` dependency on the upstream Toybox tag plus the Zig
package hash, matching the repo's existing dependency pattern.

The first pinned candidate is Toybox `0.8.14` at upstream tag commit
`b7ec52ac35e075caffca5d330995d44e8dbfc8c3`. The license is the upstream
permissive ISC-style license text shipped in Toybox `LICENSE`.

The repo should carry a small Toybox config file under `guest/minimal-initrd/`
or `scripts/`, not derive from Toybox `defconfig`. The config should enable
only the applets in the target model plus dependencies required by Toybox's
build. Compressed help should remain disabled; the spike found Toybox's
compressed-help generation produced bad `zhelp.h` bytes on macOS host tools.

The build must not execute the target aarch64 Toybox binary on the host. Applet
symlinks should be created from SporeVM's explicit supported list.

## Safety Model

- Toybox runs inside the guest as child workload code. It must not add host-side
  parsers, VMM devices, monitor control requests, or rootfs cache authority.
- `/init` remains the SporeVM guest agent and the only default boot entrypoint.
- Unsupported applets are absent, not best-effort aliases.
- Existing helper binaries win over Toybox symlinks to avoid changing product
  smoke semantics accidentally.
- The default initrd still mounts only the filesystems the agent needs for
  current run, stdin, TTY, cgroup, injection, and networking features.
- SECURITY.md must describe the new default shell environment and the fact that
  Toybox is third-party guest code, not a new host trust boundary.

## Current State

- The plan document is committed on `lox/toybox-initrd-spike`.
- `src/run.zig` wraps shell-form commands as `/bin/sh -lc`.
- The default initrd is built by `scripts/make-minimal-exec-initrd.sh` from
  source-only SporeVM helper binaries plus the pinned Toybox source dependency.
- `guest/minimal-initrd/agent.c` uses `execve(argv[0], ...)` and does no guest
  PATH lookup.
- `guest/minimal-initrd/toybox.config` enables only the first supported applet
  set, and `guest/minimal-initrd/toybox-sh.c` maps `/bin/sh -lc` to Toybox
  `sh -c`.
- `scripts/smoke-run.sh` checks shell-string `echo`, exact `/bin/echo`, bare
  `echo` no-PATH failure, and a truly missing command.
- A local spike on `lox/toybox-initrd-spike` proved the runtime path with
  Toybox 0.8.14 built static for `aarch64-linux-musl`. The initial defconfig
  Toybox cpio was about 1.3M; the implemented minimal-config cpio is about
  692K.
- The spike proved `spore run -- /bin/echo spore-smoke` and
  `spore run 'echo spore-shell-smoke'` on HVF.
- The spike also found Toybox `sh` rejects `-lc`; a tiny `/bin/sh` wrapper fixed
  compatibility without changing the rootfs shell contract.

## Delivery Strategy

### PR 1: Pinned Minimal Toybox As Default

Scope:

- add a pinned Toybox source dependency;
- add the minimal Toybox config;
- build a static aarch64 Toybox binary as part of the initrd asset step;
- add `/bin/toybox`, the `/bin/sh` compatibility wrapper, and explicit applet
  symlinks to the default initrd;
- preserve existing SporeVM helper binaries when names overlap;
- update `scripts/smoke-run.sh` so `/bin/echo` and shell-string `echo` succeed,
  while a truly missing command still exits 127 with the diagnostic;
- update README, `docs/lifecycle.md`, `guest/minimal-initrd/README.md`, and
  SECURITY.md.

Definition of done:

- default `zig build` embeds the Toybox-enabled initrd;
- no extra local Toybox binary is required to build from a clean checkout;
- `spore run 'echo hi'` and `spore run -- /bin/echo hi` pass on HVF;
- `spore run -- echo hi` still fails because exact argv has no PATH lookup;
- the embedded initrd size stays under 2MiB unless the PR explains the measured
  increase.

### PR 2: Cross-Host Release Proof

Scope:

- run the same default Toybox smoke path on Linux/KVM;
- confirm macOS and Linux release archive builds include the same pinned Toybox
  inputs;
- add a small release-note entry describing the new default initrd behavior;
- record the final size and cold-run timing delta in the plan or release notes.

Definition of done:

- required Buildkite `buildkite/sporevm` check passes;
- focused HVF and KVM smokes prove shell-form and exact `/bin/echo`;
- release archive build does not rely on unpinned host-installed Toybox.

### Follow-Up: Applet Set Review

Add or remove applets only from observed user need. Each new applet should come
with one reason and one smoke or unit-level proof when the behavior matters.

Default answer for new requests: use `--image` when the command starts to look
like distro behavior.

## Verification

Unit and build checks:

```bash
mise run test
mise run build
git diff --check
```

Focused default-initrd smokes:

```bash
zig-out/bin/spore run 'echo spore-shell-smoke'
zig-out/bin/spore run -- /bin/echo spore-smoke
zig-out/bin/spore run -- /bin/not-there
zig-out/bin/spore run -- echo spore-smoke
```

Existing product smokes:

```bash
mise run smoke:run
mise run smoke:run-stdin
mise run smoke:run-tty
```

Release and portability proof:

```bash
mise run build:release
scripts/build-release-assets.sh --target darwin-arm64 --output dist
scripts/build-release-assets.sh --target linux-arm64 --output dist
```

KVM validation should run the same command matrix on a supported Linux arm64
host before the default behavior is treated as fully shipped.

## Resolved Decisions

- Toybox should become the default shell provider for the embedded initrd.
- The first version ships a minimal applet set, not Toybox `defconfig`.
- Toybox is pinned and built from source; no prebuilt Toybox binary is checked
  into the repo.
- `/bin/sh` keeps compatibility with SporeVM's current `/bin/sh -lc` shell
  wrapper by using an initrd-local shim.
- Exact argv does not gain PATH lookup.
- `--image`, `--rootfs`, and `--initrd` remain the escape hatches for richer
  command environments.

## Deferred Work

- Revisit the global `/bin/sh -lc` wrapper only if rootfs users need a different
  shell contract. The first Toybox slice should not change rootfs behavior.
- Expand applets after real usage demonstrates a missing basic command.
- Consider SBOM or third-party-license generation when release packaging grows a
  broader dependency inventory.

## Key Learnings From Pressure-Testing

Toybox is not drop-in with SporeVM's current shell argv. The plan keeps a small
initrd-local shim instead of changing the public rootfs shell contract.

Toybox's default config is too broad for the default initrd. The plan requires a
minimal config and explicit symlink list so the embedded environment does not
quietly become a distro.

The main added risk is build and supply-chain drift, not a new VMM parser. The
plan pins source, disables the macOS-fragile compressed-help path found during
the spike, and requires clean-checkout release proof before treating the change
as shipped.
