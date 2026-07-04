---
status: active
last_reviewed: 2026-07-05
spec_refs:
  - README.md
  - docs/fanout.md
  - docs/lifecycle.md
  - docs/rootfs.md
  - src/main.zig
  - src/run_cli.zig
  - src/resume_cli.zig
  - src/lifecycle.zig
  - src/rootfs_cli.zig
  - src/fanout.zig
---

# CLI Help Consistency

## Summary

SporeVM's CLI behavior is stronger than its help surface. The first cleanup
slice makes existing commands easier to discover without adding new command
aliases or changing runtime behavior.

## Problem

Top-level help listed one-shot runs, named lifecycle, bundle operations, rootfs
tools, and local system commands in one flat list. Several commands only showed
help when `--help` was the first and only argument, so common invocations such
as `spore create bench --help` or `spore rootfs build --help` failed or printed
generic help. `spore fanout --parallel` was documented even though fan-out is
always parallel.

## Goals

- Group top-level help by user workflow.
- Keep `--json` guidance clear without adding JSON output for stream commands.
- Accept help flags before command parsing while preserving exact argv after
  `--`.
- Give rootfs and bundle subcommands command-specific help.
- Stop advertising `fanout --parallel` while continuing to accept it.
- Hide repair/internal commands from aggregate help while preserving direct
  expert invocation.

## Non-Goals

- No `spore attach` alias.
- No new command taxonomy or command moves.
- No parser framework or dependency.
- No behavior change for monitor, netd, rootfs, bundle, or fan-out execution.

## Delivery Strategy

### Slice 1: Help Surface Polish

Status: landed in this branch.

- Group top-level help into one-shot VMs, named VMs, artifacts, and local
  system/rootfs commands.
- Add command-specific help for rootfs and bundle subcommands.
- Hide `rootfs cas-preload` from `spore rootfs --help`; keep
  `spore rootfs cas-preload --help` for explicit repair/debug use.
- Recognize `help`, `-h`, and `--help` after options or positional arguments
  where that does not conflict with exact argv after `--`.
- Hide `fanout --parallel` from help and public docs while keeping parser
  compatibility.

Validation:

- `mise run build`
- `mise run test`
- targeted CLI help samples:
  - `zig-out/bin/spore help`
  - `zig-out/bin/spore create bench --help`
  - `zig-out/bin/spore run --image alpine --help`
  - `zig-out/bin/spore rootfs build --help`
  - `zig-out/bin/spore pack --help`
  - `zig-out/bin/spore fanout --help`
  - `zig-out/bin/spore rootfs cas-preload --help`
- `zig-out/bin/spore rootfs --help` omits `cas-preload`
- unit coverage for preserving guest `--help` after the exact argv delimiter
  and keeping repair commands out of aggregate help

### Follow-Up: Product Convenience Commands

Status: deferred.

Consider `spore system doctor` or `spore logs NAME` only after repeated user
need. Do not add `spore attach` unless `run --from` stops covering the session
attach workflow cleanly.

## Key Learnings From Pressure-Testing

The useful first slice is help-only. Adding aliases or moving commands would
create compatibility and documentation work without fixing the immediate UX
roughness. The parser change needs the exact-argv delimiter guard so guest
commands can still receive `--help` unchanged.
