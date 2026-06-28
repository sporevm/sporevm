---
status: active
last_reviewed: 2026-06-28
spec_refs:
  - docs/memory.md
  - docs/lifecycle.md
  - docs/spore-format.md
  - src/run.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/kvm/vm.zig
  - src/hvf/vm.zig
related_plans:
  - docs/memory.md
  - docs/lifecycle.md
  - docs/plans/automatic-local-ram-backing.md
---

# Automatic Memory and Runtime Accounting

## Summary

SporeVM should stop making users pick a small RAM value up front. Product
commands use `--memory auto`, where `auto` means a 16GiB product memory contract.
Fresh managed runs with the default kernel/initrd can now boot at a 512MiB RAM
floor and grow through a transient grow-only virtio-mem region. Capture, resume,
custom-kernel, custom-initrd, and explicit-memory paths keep the fixed-RAM
behavior that the manifest format records.

The user-facing promise is still `--memory auto`, not a public hotplug API. The
product value is that declared memory is a compatibility ceiling, while host
cost follows touched pages, dirty chunks, and, for fresh managed auto runs,
pressure-driven virtio-mem growth. `spore ls` should make that visible by
showing configured memory next to resident memory, sparse backing allocation,
chunk counts, and pending dirty work.

The product memory contract, sparse fresh-boot seeding, caught-up suspend path,
and first grow-only virtio-mem prototype have landed. The remaining
automatic-memory work is observability and evidence: cheap resident/process
accounting, nonzero and dirty chunk counters, and real-host measurements that
prove the 16GiB default stays sparse in normal product flows.

## Problem

The product CLI now uses `--memory VALUE`; omitted memory records `auto` and
resolves to a 16GiB product memory contract. Fresh managed auto runs can satisfy
that contract with a 512MiB boot RAM floor plus a transient virtio-mem growth
region. Capture and resume still serialize a normal fixed RAM size in manifest
v0. That is only a good default if operators can see the difference between
configured RAM and host cost.

The VMM has the right sparse mechanics: fresh boot maps RAM with private
anonymous `mmap`, sparse dirty seeding starts from boot-populated ranges,
same-host restore can use proof-gated `ram.backing`, memory manifests elide zero
chunks, and dirty tracking keeps chunk refs and backing files up to date while
the VM runs. The remaining product gap is that `spore ls` still lacks cheap
resident memory, nonzero chunk, and pending dirty counters, and the plan still
needs current real-host evidence for the 16GiB product path.

## Goals

- Replace product `--memory-mib N` with `--memory VALUE`.
- Make omitted `--memory` equivalent to `--memory auto`.
- Resolve `auto` to a 16GiB guest-visible RAM size for the first product slice.
- Accept unit-based memory arguments such as `512mb`, `2gb`, `16gb`, `1024mib`,
  and `17179869184b`.
- Store runtime/spec memory as bytes so the product surface matches the spore
  manifest's byte-sized `platform.ram_size`.
- For fresh managed `--memory auto` runs, allow the host to boot a smaller base
  RAM mapping and grow toward the product contract through virtio-mem pressure
  requests.
- Seed fresh-boot dirty tracking from known populated RAM ranges instead of the
  whole configured RAM range.
- Keep logical RAM cheap: fresh boot, dirty tracking, backing updates, suspend,
  and `spore ls` must not scan the whole configured RAM range.
- Make `spore ls` show memory economics directly.

## Non-Goals

- No ACPI hotplug or DTB hotplug.
- No virtio-mem unplug, host reclaim, balloon, or free-page-reporting device in
  the first prototype. That remains future work for shrinking manifests and
  reclaiming guest-free pages.
- No manifest-v0 capture of virtio-mem state. Capture, resume, named lifecycle,
  custom-kernel, custom-initrd, and explicit-memory paths keep fixed RAM until a
  deliberate format/device-model migration exists.
- No compatibility alias for `--memory-mib` in product commands unless a real
  external dependency needs it.
- No churn to lower-level harness flags such as `kvm-boot --mem-mib` or
  `hvf-boot --mem-mib` in the first slice.
- No scheduler or host admission controller. `spore ls` should expose the
  facts needed by a later scheduler, not decide fleet policy.

## Target Model

### CLI

Product commands use one memory flag:

```console
spore run --memory auto -- /bin/true
spore run --memory 16gb -- /bin/true
spore create node-ci --image docker.io/library/node:22-alpine --memory auto
spore create tiny --memory 512mb
```

If `--memory` is omitted, the parser records `auto` and resolves it to 16GiB.
Display code should preserve whether the user chose `auto` or an explicit size:

```json
{
  "memory": {
    "policy": "auto",
    "bytes": 17179869184
  }
}
```

Unit parsing should be strict and boring:

- `auto` is case-sensitive and takes no suffix.
- `b`, `kb`, `mb`, and `gb` are accepted.
- `kib`, `mib`, and `gib` are accepted aliases.
- VM memory units are binary: `1gb == 1gib == 1073741824` bytes.
- Values must be positive, whole bytes after unit conversion, and aligned to
  the host page size before VM creation.
- Overflow, unknown units, empty values, fractional values, and whitespace
  inside the value fail before any VM state is written.

### Runtime State

The lifecycle spec should move from `memory_mib` to a memory object:

```json
{
  "name": "node-ci",
  "memory": {
    "policy": "auto",
    "bytes": 17179869184
  }
}
```

The monitor CLI can keep an internal byte-sized flag if needed, but the product
path should pass bytes and avoid re-parsing MiB. The backend config already
uses byte-sized `ram_size`, so the conversion should happen once at the CLI
boundary.

### Tiny Physical Footprint

Large logical RAM is cheap only if every hot path is sparse:

- Fresh managed auto runs boot a small fixed RAM floor and expose the remaining
  auto contract as a transient grow-only virtio-mem region.
- Fixed-RAM fresh boot maps the full RAM range but only writes kernel, initrd,
  DTB, and device state that is actually needed.
- Boot planning returns populated RAM ranges so dirty tracking can seed only
  the chunks intersecting those ranges.
- New dirty-tracker state initializes the chunk-ref table as all `null` and
  materializes refs/backing data only for seeded or dirty chunks.
- VMM-originated guest RAM writes keep using the existing `GuestRam` dirty hook
  so virtio used rings and writable descriptors are recorded even when the CPU
  dirty log cannot see them.
- Same-host `ram.backing` remains sparse. Its logical size may be 16GiB, but
  allocated blocks should follow materialized chunks.
- `spore ls` reads metadata and counters. It must not walk guest RAM.

### `spore ls`

Default `spore ls` should become a human table. `spore --json ls` should remain
the stable machine-readable API.

```console
$ spore ls
NAME      STATE  PID    MEMORY  RESIDENT  BACKING      CHUNKS    DIRTY
node-ci   ready  44129  auto    184MiB    34MiB/16GiB  17/8192   2
tiny      ready  44188  512MiB  72MiB     none         ?         ?
```

The JSON form should expose raw numbers and nullable fields:

```json
{
  "name": "node-ci",
  "state": "ready",
  "pid": 44129,
  "memory": {
    "policy": "auto",
    "bytes": 17179869184
  },
  "stats": {
    "resident_bytes": 188743680,
    "backing_logical_bytes": 17179869184,
    "backing_allocated_bytes": 35651584,
    "chunk_size": 2097152,
    "chunks_total": 8192,
    "chunks_nonzero": 17,
    "dirty_chunks_pending": 2
  }
}
```

The first implementation can report `null` for fields that a backend or
platform cannot supply yet. It should prefer unknown values over expensive
best-effort scans.

## Current State

- Slice 2 is implemented in the product CLI: `spore run`, `spore create`, and
  `spore monitor` use `--memory VALUE`, omitted `--memory` records `auto`, and
  `auto` resolves to a 16GiB byte-sized RAM contract.
- Lifecycle specs persist `memory.policy` plus resolved `memory.bytes` instead
  of `memory_mib`.
- `spore resume` derives RAM size from `manifest.platform.ram_size`.
- KVM and HVF backend configs already accept byte-sized `ram_size`.
- Fresh KVM/HVF boot maps RAM with demand-committed anonymous private mappings.
- Proof-gated same-host resume can map a same-sized `ram.backing` fd with
  `MAP_PRIVATE`.
- Memory manifests already store byte-sized platform RAM, 2MiB chunk refs, and
  optional local backing metadata.
- Always-on dirty tracking is implemented for the current product target:
  caught-up dirty tracking avoids suspend-time full-RAM scans on KVM and HVF.
- Dirty RAM sealing is now shared in `src/dirty_ram.zig`, but initial seeding
  still defaults to scanning every configured chunk unless callers provide a
  narrower seed set.
- Slice 1 pre-work is implemented in the sparse dirty RAM seed PR:
  `boot.load` reports the kernel, initrd, and DTB ranges it wrote; the shared
  dirty RAM sealer accepts optional seed ranges; fresh KVM and HVF boot paths
  pass those ranges into dirty tracking. Resume paths deliberately keep the old
  full seed until a separate sparse-resume seed source exists.
- Fresh product `spore run --capture` paths now enable backend dirty tracking
  for base captures. Product capture uses tail-only sealing for the final dirty
  set, which avoids the 16GiB full-RAM scan while preserving coherent
  run-bridge/vsock state for forked children.
- Fresh managed default-kernel/default-initrd `spore run --memory auto` paths
  now boot 512MiB of fixed RAM and expose the remaining auto contract through a
  transient grow-only virtio-mem region. The guest agent reports cgroup
  `memory.events` pressure over the existing run bridge; KVM and HVF request
  1GiB virtio-mem growth steps and map hotplug memory on guest plug requests.
  Capture, resume, custom assets, named lifecycle, and explicit memory keep the
  old fixed-RAM behavior.
- `spore ls` now includes lifecycle-spec memory policy and configured bytes in
  human and JSON output. It derives chunk size and total chunks from the
  configured memory contract, reports Linux/macOS monitor process resident
  bytes for ready VMs, and reports local `ram.backing` logical and allocated
  bytes with metadata-only file stats when the lifecycle spec points at a local
  spore directory. Nonzero chunk and dirty counters remain explicitly unknown
  until they have cheap runtime metadata or monitor sources.
- The current stats collector deliberately lives in `src/lifecycle.zig`: it
  combines lifecycle spec metadata, process resident metadata, and sparse
  backing file stats for one list call path. Do not extract a
  runtime-accounting module until monitor-emitted nonzero and dirty counters
  create a real second runtime source.

## Delivery Strategy

### Slice 1: Sparse Fresh-Boot Dirty-Tracker Seeding

Make fresh-boot dirty tracking seed only known populated ranges instead of
scanning every chunk. `boot.load` should expose the kernel, initrd, and DTB
ranges it wrote. The shared dirty RAM sealer should initialize refs to all-null,
seal only those ranges, and rely on dirty logs/write-protect faults plus
`GuestRam` dirty hooks after guest entry.

Status: landed in PR #100 and validated on HVF plus KVM 16GiB idle
dirty-tracking benchmarks.

Done when:

- 16GiB dirty-tracked fresh boot no longer spends seconds scanning zero RAM
  before the guest runs.
- Sparse `ram.backing` allocated bytes remain close to the materialized working
  set for a minimal boot.
- Existing dirty-tracking restore and same-host backing smokes still pass.

### Slice 2: Product CLI Contract

Add a small shared memory parser and convert product commands to `--memory`.
Update `spore run`, `spore create`, lifecycle spec writing, monitor spawning,
and help text. Persist memory policy plus bytes in lifecycle specs.

Status: landed.

Done when:

- `spore run --memory auto`, `spore run --memory 16gb`, and omitted `--memory`
  pass the expected byte-sized RAM to the backend.
- `--memory-mib` is rejected on product commands.
- Unit parser tests cover accepted units, overflow, bad suffixes, zero, and
  alignment failures.

### Slice 3: `spore ls` Human and JSON Memory Stats

Extend monitor/runtime metadata with cheap memory accounting and teach
`spore ls` to render a table by default plus full JSON under global `--json`.

Done when:

- `spore ls` shows memory policy, configured bytes, process or mapping
  resident bytes, sparse backing allocation, chunk totals, nonzero chunks, and
  pending dirty chunks where available.
- Fields that cannot be collected on a platform render as `?` in the table and
  `null` in JSON.
- `spore ls` remains O(number of VMs), not O(total configured RAM).

Progress:

- First visibility slice: lifecycle list output reads `memory.policy` and
  `memory.bytes` from each VM's `spec.json` and emits nullable stat fields
  instead of trying to derive them by walking RAM.
- The human `spore ls` table now renders populated nullable stats when a cheap
  runtime, process, or filesystem metadata source supplies them. Nonzero chunk
  and dirty collection sources are still pending.
- Lifecycle list entries now derive `chunk_size` and `chunks_total` from the
  configured memory contract, and derive sparse backing logical/allocated bytes
  from no-follow `ram.backing` file stats when a local resume directory is
  known. Ready VMs now get resident bytes from bounded process metadata
  (`/proc/<pid>/statm` on Linux, `proc_pidinfo` on macOS). Nonzero chunks and
  pending dirty chunks still need monitor sources.
- Keep the collector lifecycle-local until monitor counters land. Once there
  are multiple runtime-owned sources, split around a small list-facing collector
  that preserves the O(number of VMs) contract instead of adding a wrapper
  around today's lifecycle implementation.

### Slice 4: Measurement Gate for Raising Defaults Further

Run real-host smokes with the 16GiB auto default and record create latency,
guest boot progress, resident memory, backing allocation, suspend pause, and
dirty tail across KVM and HVF. Only after those numbers are stable should the
project consider larger auto values.

Done when:

- KVM and HVF have representative 16GiB product-path runs in `docs/memory.md`
  or this plan's progress snapshot.
- The results distinguish configured RAM from resident/private memory.

## Verification

- Unit tests for memory parsing and lifecycle spec JSON round-trips.
- Slice 2 validation on 2026-06-18: `mise run check` passed with product memory
  parser, run parser, create parser, and lifecycle spec round-trip coverage;
  command-level checks confirmed `spore run`, `spore create`, and
  `spore monitor` reject `--memory-mib`.
- Unit tests for range-to-chunk seeding, including edge-aligned kernel/initrd
  and DTB ranges.
- Existing `mise run test` suite.
- Dirty-tracking benchmark at 16GiB showing fresh-boot `seed_chunks` and
  `seed_ms` follow boot-populated ranges, not configured RAM size.
- HVF validation on 2026-06-18: `scripts/benchmark-kvm-dirty-tracking.sh
  --backend hvf --modes write-protect --initrd-mode idle --mem-mib-list
  "16384" --snapshot-after-ms 3000 --dirty-epoch-ms 250 --iterations 1`
  reported 8192 configured chunks, `seed_chunks=5`, `seed_nonzero_chunks=5`,
  `seed_ms=386`, `seed_protect_ms=8`, `snapshot_pause_ms=103`, and a 16GiB
  `ram.backing` with 264MiB allocated.
- KVM validation on 2026-06-18: the same benchmark on an aarch64 metal dev host
  with `--backend kvm --modes dirty-log` reported 8192 configured chunks,
  `seed_chunks=5`, `seed_nonzero_chunks=5`, `seed_ms=425`,
  `snapshot_pause_ms=1471`, and a 16GiB `ram.backing` with 262MiB allocated.
- Product smoke: `spore run --memory auto -- /bin/true`.
- Product lifecycle smoke: create, exec, `spore ls`, suspend or rm.
- Same-host fork/fan-out smoke reporting declared RAM versus aggregate PSS/RSS.
- HVF product capture validation on 2026-06-20: a mostly-idle 16GiB
  `spore run --backend hvf --memory auto --capture <base.spore> --capture-on
  USR1 -- /bin/counter` baseline took 25.724s from `USR1` to exit with the
  full-scan path. Enabling product dirty tracking with tail-only sealing reduced
  the same measurement to 1.870s, with 8192 chunks, 132 populated refs, 8060
  zero-elided chunks, and a 16GiB `ram.backing` allocated at about 264MiB.
  `SPORE_SMOKE_FANOUT_COUNT=3 scripts/smoke-counter-fanout.sh` passed with the
  default 20s capture timeout.
- Automatic local `ram.backing` restore is proof-gated, not flag-gated.
  `docs/plans/automatic-local-ram-backing.md` tracks the local provenance
  contract: product restore paths can use a validated same-host backing fd, while
  missing or invalid proof falls back to chunks with no user-facing trust mode.

## Key Learnings From Pressure-Testing

- `auto=16gb` is a UX change only if create and suspend stay sparse. Slice 7
  makes caught-up suspend sparse; fresh-boot seeding must also stop scanning
  every chunk to discover zeros.
- `spore ls` can accidentally become the new scaling bug. Every displayed field
  must come from runtime metadata, monitor counters, sparse-file stat data, or
  OS process accounting. It must never sample by reading guest RAM.
- The persisted spore contract is still fixed RAM. The first virtio-mem slice is
  deliberately fresh-run-only so the manifest platform contract does not grow
  before capture/resume semantics are designed.
- The lower-level boot harnesses should keep their current `--mem-mib` flags
  for the first slice. Churning every smoke script at once would make the
  product CLI change harder to review without improving the user contract.
- Sparse fresh-boot seed removes the pre-guest full-RAM scan, but it does not
  make boot dirties disappear. The first HVF 16GiB idle run still sealed 132
  non-zero chunks after guest entry with a 24.8s worker epoch; suspend pause
  stayed 103ms because the tail was one chunk.
- KVM showed the same sparse seed shape, but the measured suspend pause was
  1471ms because the final dirty tail still had 136 chunks. That is useful
  evidence for the next worker/tail tuning pass, not a reason to make fresh
  seed scan configured RAM again.
- Product signal capture is more sensitive than the backend idle benchmark:
  periodic HVF worker sealing with an active run-bridge/vsock session produced
  a fast manifest that resumed the inherited counter but did not accept fork
  identity. Tail-only product sealing kept capture under the smoke watchdog and
  preserved fork/fan-out correctness. Re-enabling periodic product sealing needs
  a dedicated run-bridge coherence proof.

## Resolved Decisions

- Product `--memory` defaults to `auto`.
- `auto` resolves to 16GiB in the first product slice.
- Product commands drop `--memory-mib` instead of keeping a compatibility alias.
- Unit suffixes are accepted on product commands, and `gb`/`mb` use binary VM
  units.
- Runtime specs store both the user policy and byte-sized resolved memory.
- `spore --json ls` is the stable machine-readable output. The default output
  is a human table.

## Deferred Work

- Virtio-mem unplug, reclaim, and capture/resume semantics.
- Memory ballooning and free-page reporting.
- Host admission control and fleet scheduling based on observed memory.
- Raising `auto` beyond 16GiB.
- Renaming low-level harness memory flags.

## Open Questions

No blocking questions for the landed slices. Remaining work needs
platform-specific choices for exact resident-memory accounting, especially on
macOS, but unknown values can be represented explicitly until a cheap source is
proven.
