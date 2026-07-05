---
status: landed
last_reviewed: 2026-07-05
spec_refs:
  - README.md
  - docs/fanout.md
  - docs/lifecycle.md
  - docs/rootfs.md
  - docs/spore-format.md
  - src/main.zig
  - src/run.zig
  - src/resume.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/fanout.zig
related_plans:
  - docs/plans/cli-help-consistency.md
  - docs/plans/interactive-input-tty.md
  - docs/plans/named-lifecycle-contract-hardening.md
---

# Spore Naming And CLI UX

## Summary

SporeVM should present one durable public object: a spore. A spore is saved VM
state: memory, CPU/device state, and storage identity or data. Sessions are an
optional part of a spore, not a separate artifact kind.

The CLI should make that model obvious. Commands that write spores should say
`save`; named VM `save` should keep the VM running unless the user explicitly
passes `--stop`. Commands that run a new command from a spore should stay under
`run --from`. Commands that connect to a saved session should say `attach`.
Commands that turn a spore back into a named VM should say `restore`.

Breaking CLI changes are acceptable for this cleanup. The plan should avoid
compatibility aliases unless release timing explicitly requires them.

## Problem

The current CLI uses several near-synonyms for different parts of the same
model:

- `checkpoint` appears in help and docs even though the public artifact is a
  spore.
- `capture` sometimes means "write a spore" and sometimes implies a captured
  process session.
- `suspend` writes a spore from a named VM and consumes the live VM, but does
  not necessarily create a new captured session.
- `resume` is overloaded: `spore resume DIR` connects to a saved session, while
  `spore resume DIR --name NAME` restores a named VM.

That makes fan-out constraints hard to understand. Users need one rule:

```text
A spore always contains VM state.
A spore may also contain sessions.
Only spores with sessions can attach to or fan out the original command.
```

## Goals

- Use `spore` as the public artifact noun in CLI help, docs, and errors.
- Keep `session` as the public and manifest noun for captured command streams.
- Rename write-spore operations to `save`.
- Make named VM `save` non-destructive by default.
- Keep destructive named VM save explicit through `save --stop`.
- Add `attach` for saved sessions.
- Rename named-VM restore operations to `restore`.
- Remove public `resume` to avoid overlap with `restore`.
- Make `inspect`, `attach`, `fanout`, and `run --from` explain the sessions requirement
  before users discover it by trial.
- Keep command examples copy-pasteable and validated against the implemented
  parser.

## Non-Goals

- No spore format change.
- No manifest field rename from `sessions`.
- No new VM lifecycle daemon or registry model.
- No broad behavior expansion for disk-backed live fork, chunked metadata-only
  bundles, or network-flow checkpointing.
- No broad parser framework. Rename the existing command and flag surface in
  place.

## Target Model

### Concepts

- **Spore**: saved VM state, including memory, CPU/device state, and storage
  identity or data.
- **Session**: optional captured command stream recorded in a spore.
- **Named VM**: live runtime handle for repeated `exec`, `save`, `restore`, and
  live fork workflows.
- **Bundle**: transport wrapper for one or more spores.

### CLI Surface

Write a spore from a run:

```bash
spore run --save base.spore --save-on TERM \
  'while true; do echo tick; sleep 1; done'
```

Because `run` owns a command, `run --save` writes VM state plus a session for
that command.

Use a saved spore:

```bash
spore run --from base.spore 'cat /var/tmp/example'
```

`run --from` restores VM state and starts a new command. It does not attach to
saved sessions; commandless `run --from DIR` should fail with a short pointer to
`spore attach DIR`.

Attach to a saved session:

```bash
spore attach base.spore
spore attach base.spore --session default
spore attach -it live-shell.spore
```

`attach` restores VM state and connects to a recorded session. It requires
`Sessions > 0`, defaults to the `default` session when present or the sole
recorded session when there is only one non-default session, and accepts
`--session ID` for explicit selection. `-i` and `-t` must match the recorded
session's stream capabilities. `attach` does not create a named VM and does not
start a new command.

Save and restore named VMs:

```bash
spore save bench-1 --out bench-1.spore
spore restore bench-1.spore --name bench-2
```

`spore save NAME` writes a spore and leaves the named VM running. It preserves
existing sessions if the named VM was restored from a spore that had sessions,
but it does not invent a new session for earlier `exec` commands.

Stop after saving when the caller wants a consuming lifecycle transition:

```bash
spore save bench-1 --out bench-1.spore --stop
```

`spore save --stop` writes the spore, stops the named VM, and removes it from
the runtime registry.

Fork and fan out:

```bash
spore fork base.spore --count 2 --out children
spore fanout children --for 10s
```

`fork` copies VM state and any recorded sessions. `fanout` attaches to sessions
across child spores and therefore requires child spores with sessions.

### Rename Table

| Current spelling | New spelling | Meaning |
| --- | --- | --- |
| `spore run --capture DIR` | `spore run --save DIR` | Run a command and save a spore. |
| `spore run --capture-on WHEN` | `spore run --save-on WHEN` | Save trigger for the run. |
| `--continue-after-capture` | `--continue-after-save` | Keep running after the save trigger. |
| commandless `spore run --from DIR` | `spore attach DIR` | Restore VM state and attach to a saved session. |
| `spore resume DIR` | `spore attach DIR` | Restore VM state and attach to a saved session. |
| `spore suspend NAME --out DIR` | `spore save NAME --out DIR --stop` | Stop a named VM and write a spore. |
| internal named snapshot | `spore save NAME --out DIR` | Write a spore and keep the named VM running. |
| `spore resume DIR --name NAME` | `spore restore DIR --name NAME` | Restore a spore as a named VM. |
| `checkpoint` in help/docs | `spore` | Public artifact noun. |

By default, old spellings should be removed from public help and docs. If a
release needs compatibility, add hidden parser aliases in the same command
adapters and keep them out of examples.

## User-Facing Output

Human lifecycle output should avoid "captured" unless a session was captured:

```text
saved bench-1.spore; vm bench-1 is still running
```

For consuming saves:

```text
saved bench-1.spore and stopped vm bench-1
```

Machine-only saves should explain the session consequence:

```text
spore has no saved session; use `spore run --from <spore> ...` to run new
commands, or `spore run --save <spore> --save-on TERM ...` if you want fanout
to attach to the original command.
```

`inspect` should lead with the artifact model:

```text
Spore: bench-1.spore
VM state: memory, devices, storage
Storage: exact
Sessions: none
```

`fanout` errors should translate the manifest state into the workflow rule:

```text
fanout requires child spores with sessions

children/000000 has Sessions: none.
Use `spore inspect children/000000` to check sessions.
Use `spore run --save base.spore ...` when you want fanout to attach to the
original command.
```

`attach` should fail before restoring machine state when the spore has no
sessions:

```text
attach requires a spore with sessions

base.spore has Sessions: none.
Use `spore inspect base.spore` to check sessions.
Use `spore run --from base.spore <cmd>` to run a new command.
Use `spore run --save base.spore ...` when you want to attach later.
```

## Implementation Status

- `src/run.zig` now exposes `--save`, `--save-on`, and
  `--continue-after-save`; old save flag spellings are intentionally absent
  from public help.
- Commandless `spore run --from DIR` now fails at the CLI boundary with a
  pointer to `spore attach DIR`.
- `spore attach DIR [--session ID] [-i|-t]` uses the direct session attach
  path, preflights sessions before network binding, gateway startup, or restore,
  passes live bound-service bindings through the CLI adapter, and supports
  generation injection for fanout and single-child adapters.
- `spore save NAME --out DIR` uses the internal snapshot-and-continue monitor
  action and publishes through a temporary sibling before atomically renaming
  the completed spore into place.
- `spore save NAME --out DIR --stop` uses the existing consuming stop-and-save
  monitor operation.
- `spore restore DIR --name NAME` replaces named lifecycle `resume --name`.
- Public help, README, focused docs, smoke scripts, and parser tests have been
  moved to the new vocabulary.
- There is no checked-in changelog in this repo. The release-note content below
  is the durable draft for the generated GitHub release notes.

## Delivery Strategy

Land the following tracks together in one PR. The headings are review tracks,
not staged release phases.

### Single PR: Public CLI Rename And Behavior

Scope:

- replace `run --capture*` flags with `run --save*`;
- require a command for `run --from DIR <cmd>` and make commandless
  `run --from DIR` point to `spore attach DIR`;
- add `attach DIR [--session ID]` for saved sessions;
- add `save NAME --out DIR` as the non-destructive named VM spore write path;
- add `save NAME --out DIR --stop` as the consuming save path that replaces
  `suspend`;
- replace named `resume --name` dispatch with `restore --name`;
- remove public `resume DIR`;
- update help text, human errors, README examples, focused docs, smoke scripts,
  benchmark scripts, and CLI parser tests;
- update `inspect` and `fanout` wording around spores and sessions.

Definition of done:

- public help and docs use `spore`, `save`, `restore`, and `sessions`;
- no copy-pasteable example uses `checkpoint`, `--capture`, `suspend`, or
  `resume --name`;
- `spore save NAME --out DIR` leaves `NAME` ready for a later `exec`;
- `spore save NAME --out DIR --stop` writes the spore and removes `NAME` from
  the runtime registry;
- `spore attach DIR` preflights sessions before restoring VM state and gives
  the same inspect/run guidance as fanout when `Sessions: none`;
- `spore attach DIR --session ID` rejects unknown sessions before restore;
- `spore attach -i/-t DIR` rejects unsupported stream capabilities before
  restore;
- commandless `spore run --from DIR` fails with a direct `spore attach DIR`
  suggestion;
- public `spore resume` help and dispatch are gone or, if retained briefly for
  compatibility, hidden and routed to `attach`/`restore` with deprecation
  output outside machine mode;
- non-destructive named `save` writes to a temporary sibling directory and
  atomically renames it into `--out` only after manifest, lifecycle metadata,
  annotations, and local backing proof files are complete;
- failed non-destructive named `save` cleans up temporary output and does not
  leave a plausible partial spore at `--out`;
- `spore save --help` documents any non-destructive save support boundary and
  names `save --stop` as the fallback until that boundary is removed;
- unsupported non-destructive save modes fail before claiming success and point
  to `save --stop` when that consuming path is supported;
- old spellings are either removed or hidden behind explicit compatibility
  aliases chosen for the release.

### Machine Output And Library Boundary

Scope:

- rename human CLI output first;
- keep existing JSONL schema fields such as `event:"capture"` under the current
  `run-events.v1` schema;
- keep C/Go/libspore symbols such as `suspendNamed` as lower-level
  implementation terms for this PR;
- keep manifest `sessions` unchanged.

Definition of done:

- machine-output compatibility is explicit rather than accidentally renamed;
- public library docs match the final CLI vocabulary where possible and explain
  any lower-level internal term that remains;
- release notes state that human CLI naming changed while the current JSONL
  schema names did not.

### Release Cleanup

Scope:

- add release notes with old-to-new command examples;
- run a final `rg` pass over public docs, scripts, and help fixtures;
- remove any temporary compatibility aliases if the release is intentionally
  hard-breaking.

Definition of done:

- the release note teaches the new model in one screen;
- public docs have one noun for the artifact and one rule for sessions.

Release-note draft:

```text
SporeVM now uses one public artifact noun: a spore. A spore always contains VM
state and may also contain saved sessions. Use `spore inspect <spore>` and check
`Sessions:` before attaching or fanning out an original command.

Breaking CLI renames:
- `spore run --capture DIR` is now `spore run --save DIR`
- `spore run --capture-on TERM` is now `spore run --save-on TERM`
- `--continue-after-capture` is now `--continue-after-save`
- commandless `spore run --from DIR` is now `spore attach DIR`
- `spore resume DIR` is now `spore attach DIR`
- `spore suspend NAME --out DIR` is now
  `spore save NAME --out DIR --stop`
- `spore resume DIR --name NAME` is now `spore restore DIR --name NAME`

Named `spore save NAME --out DIR` is non-destructive by default and leaves the
named VM running. Add `--stop` when you want the old consuming lifecycle
transition.
```

## Verification

- `mise run build`
- `mise run test`
- targeted help samples:
  - `zig-out/bin/spore help`
  - `zig-out/bin/spore run --help`
  - `zig-out/bin/spore attach --help`
  - `zig-out/bin/spore save --help`
  - `zig-out/bin/spore restore --help`
  - `zig-out/bin/spore fanout --help`
  - `zig-out/bin/spore inspect <sample-spore>`
- smoke coverage:
  - `spore attach <saved-session.spore>`;
  - `spore attach <machine-only.spore>` fails before restore with inspect
    guidance;
  - commandless `spore run --from <saved-session.spore>` points to
    `spore attach`;
  - named `spore save NAME --out DIR` followed by `spore exec NAME ...`;
  - named `spore save NAME --out DIR --stop` followed by a registry check that
    `NAME` is gone;
  - forced post-snapshot named `save` failure leaves no `--out` directory and
    cleans up temporary output;
  - `mise run smoke:run-capture` renamed to the save workflow or replaced with
    an equivalent save smoke;
  - `mise run smoke:run-attach`;
  - `mise run smoke:rootfs-fanout`;
  - `mise run smoke:lifecycle-tty`;
  - `mise run smoke:monitor-failure-modes`.
- `rg` checks over public docs and scripts for stale terms:
  - `--capture`
  - `--capture-on`
  - `continue-after-capture`
  - `spore suspend`
  - `spore resume`
  - `resume .*--name`
  - user-facing `checkpoint`
  Exclude this plan and release migration notes from the stale-term gate when
  they intentionally mention old spellings.

## Resolved Decisions

- The public artifact noun is `spore`.
- `sessions` remains the noun for captured command streams.
- `save` means "write a spore".
- Named VM `save` is non-destructive by default.
- `save --stop` is the explicit consuming save operation.
- `restore` means "turn a spore back into a named VM".
- `attach` means "restore VM state and connect to a saved session".
- `resume` is not a public CLI verb.
- Breaking CLI changes are acceptable; compatibility aliases are not part of
  the default plan. Removed spellings (`resume`, `suspend`, `run --capture*`)
  fail with a redirect hint naming the replacement; they never execute.

## Deferred Work

- Rename libspore/C/Go symbols only after the CLI rename is settled. The CLI
  wording can move first because it is the sharpest UX surface.
- Multi-vCPU non-destructive named `save` can follow after the first public
  rename. The single rename PR should fail closed instead of silently falling
  back to a consuming save.
- Consider a future `inspect` schema change that reports `VM state` and storage
  mode more explicitly in JSON, after the human output model lands.

## Key Learnings From Pressure-Testing

The main failure mode is making `save` sound harmless while it consumes a named
VM. The plan fixes that by making named `save` non-destructive by default and
requiring `save --stop` for the old consuming behavior.

The second failure mode is keeping `resume` overloaded. The plan fixes that by
removing public `resume`: `attach` owns saved sessions, `restore` owns named VM
restoration, and `run --from` owns new commands from saved state.

The third failure mode is leaving partial spores behind when non-destructive
`save` fails after the monitor snapshot. The plan requires temporary output plus
atomic publish, or equivalent cleanup, before `save` can claim success.

The fourth failure mode is renaming human CLI output and accidentally breaking
machine schemas. The plan separates CLI wording from JSONL event schema work so
that any machine-output change is deliberate and versioned.

The fifth failure mode is over-explaining with new artifact kinds. The plan does
not introduce "machine checkpoint" or "session checkpoint"; it keeps one
artifact, a spore, with optional sessions.
