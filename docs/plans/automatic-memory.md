---
status: active
last_reviewed: 2026-06-18
spec_refs:
  - docs/plans/foundation.md
  - docs/plans/lifecycle-monitor.md
  - docs/spore-format.md
  - src/run.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/kvm/vm.zig
  - src/hvf/vm.zig
related_plans:
  - docs/plans/foundation.md
  - docs/plans/lifecycle-monitor.md
---

# Automatic Memory and Runtime Accounting

## Summary

SporeVM should stop making users pick a small RAM value up front. Product
commands should move toward `--memory auto`, where `auto` means a 16GiB
guest-visible RAM contract backed by demand-committed host mappings, sparse RAM
backing files, dirty tracking, and content-addressed chunks.

The user-facing promise is not guest-visible hotplug. The guest sees a normal
fixed RAM size. The product value is that declared RAM is a compatibility
ceiling, while host cost is based on touched pages and dirty chunks. `spore ls`
should make that visible by showing configured memory next to resident memory,
sparse backing allocation, chunk counts, and pending dirty work.

Foundation Slice 7 has landed the fast caught-up suspend model: dirty-tracked
KVM and HVF snapshots avoid a suspend-time full-RAM scan when the dirty tail is
small. The remaining automatic-memory blocker is earlier in the lifecycle:
initial dirty-tracker seeding must not scan every configured RAM chunk before
the guest runs.

## Problem

The current product CLI uses `--memory-mib` and defaults to 1024MiB for
`spore run`, `spore create`, and the monitor path. That keeps early tests small,
but it pushes capacity decisions onto the user and makes VM reuse feel more
manual than it needs to be.

The VMM already has many of the right mechanics: fresh boot maps RAM with
private anonymous `mmap`, same-host restore can map `ram.backing` privately,
memory manifests elide zero chunks, and Slice 7 dirty tracking keeps chunk refs
and backing files up to date while the VM runs. The remaining product gap is
that the public CLI, runtime registry, and `spore ls` do not expose memory as a
large logical contract with small observed host cost.

There is still a scaling trap: initial dirty-tracking seed paths scan every 2MiB
chunk to initialize chunk refs and `ram.backing`. That is acceptable for small
defaults, but it makes `auto=16gb` visibly expensive before the guest can do
useful work. The product default must not land until fresh-boot seeding is based
on the kernel/initrd/DTB ranges the VMM actually populated.

## Goals

- Replace product `--memory-mib N` with `--memory VALUE`.
- Make omitted `--memory` equivalent to `--memory auto`.
- Resolve `auto` to a 16GiB guest-visible RAM size for the first product slice.
- Accept unit-based memory arguments such as `512mb`, `2gb`, `16gb`, `1024mib`,
  and `17179869184b`.
- Store runtime/spec memory as bytes so the product surface matches the spore
  manifest's byte-sized `platform.ram_size`.
- Seed fresh-boot dirty tracking from known populated RAM ranges instead of the
  whole configured RAM range.
- Keep logical RAM cheap: fresh boot, dirty tracking, backing updates, suspend,
  and `spore ls` must not scan the whole configured RAM range.
- Make `spore ls` show memory economics directly.

## Non-Goals

- No virtio-mem, ACPI hotplug, DTB hotplug, or guest-visible memory resizing in
  this plan.
- No balloon or free-page-reporting device in the first slice. That remains
  future work for shrinking manifests and reclaiming guest-free pages.
- No compatibility alias for `--memory-mib` in product commands. The project is
  pre-1.0 and the public surface can break.
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

- Fresh boot maps the full RAM range but only writes kernel, initrd, DTB, and
  device state that is actually needed.
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

Default `spore ls` should become a human table. `spore ls --json` should remain
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

- `spore run`, `spore create`, and `spore monitor` use `memory_mib` with a
  1024MiB default.
- `spore resume` derives RAM size from `manifest.platform.ram_size`.
- KVM and HVF backend configs already accept byte-sized `ram_size`.
- Fresh KVM/HVF boot maps RAM with demand-committed anonymous private mappings.
- Trusted same-host resume can map a same-sized `ram.backing` fd with
  `MAP_PRIVATE`.
- Memory manifests already store byte-sized platform RAM, 2MiB chunk refs, and
  optional local backing metadata.
- Foundation Slice 7 is complete for the foundation target: caught-up dirty
  tracking avoids suspend-time full-RAM scans on KVM and HVF.
- Dirty RAM sealing is now shared in `src/dirty_ram.zig`, but initial seeding
  still defaults to scanning every configured chunk unless callers provide a
  narrower seed set.
- Slice 1 pre-work is implemented in the sparse dirty RAM seed PR:
  `boot.load` reports the kernel, initrd, and DTB ranges it wrote; the shared
  dirty RAM sealer accepts optional seed ranges; fresh KVM and HVF boot paths
  pass those ranges into dirty tracking. Resume paths deliberately keep the old
  full seed until a separate sparse-resume seed source exists.
- `spore ls` currently emits JSON with `name`, `state`, and `pid`.

## Delivery Strategy

### Slice 1: Sparse Fresh-Boot Dirty-Tracker Seeding

Make fresh-boot dirty tracking seed only known populated ranges instead of
scanning every chunk. `boot.load` should expose the kernel, initrd, and DTB
ranges it wrote. The shared dirty RAM sealer should initialize refs to all-null,
seal only those ranges, and rely on dirty logs/write-protect faults plus
`GuestRam` dirty hooks after guest entry.

Status: implemented locally and validated on HVF plus KVM 16GiB idle
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

Done when:

- `spore run --memory auto`, `spore run --memory 16gb`, and omitted `--memory`
  pass the expected byte-sized RAM to the backend.
- `--memory-mib` is rejected on product commands.
- Unit parser tests cover accepted units, overflow, bad suffixes, zero, and
  alignment failures.

### Slice 3: `spore ls` Human and JSON Memory Stats

Extend monitor/runtime metadata with cheap memory accounting and teach
`spore ls` to render a table by default plus full JSON under `--json`.

Done when:

- `spore ls` shows memory policy, configured bytes, process or mapping
  resident bytes, sparse backing allocation, chunk totals, nonzero chunks, and
  pending dirty chunks where available.
- Fields that cannot be collected on a platform render as `?` in the table and
  `null` in JSON.
- `spore ls` remains O(number of VMs), not O(total configured RAM).

### Slice 4: Measurement Gate for Raising Defaults Further

Run real-host smokes with the 16GiB auto default and record create latency,
guest boot progress, resident memory, backing allocation, suspend pause, and
dirty tail across KVM and HVF. Only after those numbers are stable should the
project consider larger auto values.

Done when:

- KVM and HVF have representative 16GiB product-path runs in the foundation
  plan or this plan's progress snapshot.
- The results distinguish configured RAM from resident/private memory.

## Verification

- Unit tests for memory parsing and lifecycle spec JSON round-trips.
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

## Key Learnings From Pressure-Testing

- `auto=16gb` is a UX change only if create and suspend stay sparse. Slice 7
  makes caught-up suspend sparse; fresh-boot seeding must also stop scanning
  every chunk to discover zeros.
- `spore ls` can accidentally become the new scaling bug. Every displayed field
  must come from runtime metadata, monitor counters, sparse-file stat data, or
  OS process accounting. It must never sample by reading guest RAM.
- Guest-visible RAM is still fixed. This plan deliberately avoids virtio-mem
  and hotplug so the frozen device model and manifest platform contract do not
  grow before the simpler sparse-ceiling model is proven.
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

## Resolved Decisions

- Product `--memory` defaults to `auto`.
- `auto` resolves to 16GiB in the first product slice.
- Product commands drop `--memory-mib` instead of keeping a compatibility alias.
- Unit suffixes are accepted on product commands, and `gb`/`mb` use binary VM
  units.
- Runtime specs store both the user policy and byte-sized resolved memory.
- `spore ls --json` is the stable machine-readable output. The default output
  can become a human table.

## Deferred Work

- Memory ballooning and free-page reporting.
- Guest-visible memory hotplug through virtio-mem or another device.
- Host admission control and fleet scheduling based on observed memory.
- Raising `auto` beyond 16GiB.
- Renaming low-level harness memory flags.

## Open Questions

No blocking questions for Slice 1. Later slices need platform-specific choices
for exact resident-memory accounting, especially on macOS, but unknown values
can be represented explicitly until a cheap source is proven.
