# Fan-Out

`spore checkpoint fork` mints local child checkpoints, and `spore fanout`
attaches those children with prefixed output:

```bash
spore checkpoint fork warm.spore --count 5 --out children/
spore fanout children/
```

Children are named `000000` through zero-padded `N-1` and share the parent's
chunk store. `spore fanout` is local orchestration over child spore directories;
distributed offset/range partitioning is deferred.

`spore checkpoint fork` preserves the source checkpoint's manifest version and
vCPU count. A
source saved with `--vcpus 4` mints children that also restore with 4 vCPUs;
fork does not downshift an already-booted guest to a smaller CPU topology.

For a running named VM, `spore vm fork NAME --count N --name PATTERN` creates
ready named children directly. Disk-backed sources use a queue-drained,
single-epoch RAM/machine capture plus independent disk heads, so siblings
inherit the same bytes and then diverge without a read-depth chain. Physical
overrides use native-cloned heads by default; after a successful save commits
the exact baseline, an override-free fork uses fresh sparse heads. The
supported disk shape is one writable rootfs device; networked live fork remains
unsupported. See [Named Lifecycle](lifecycle.md#saves-and-forks) for the
fallback, readiness, and baseline-lease contract.

Fan-out attaches to the saved process session. Machine-only spores can
still start new commands with `spore run --from`, but they cannot fan out the
original command stream:

| Spore source | Sessions | Good for fanout | Good for `run --from <cmd>` |
| --- | --- | --- | --- |
| `spore save NAME --stop` | none | no | yes |
| `spore run --save` | saved session | yes | yes |
| `spore checkpoint fork base.spore` | inherits parent | if parent has one | yes |
| `spore unpack bundle --child N` | inherits bundled child | if child has one | yes |

If the parent manifest declares bound services, fan-out supplies one fresh host
socket binding per service and applies the same binding to every child:

```bash
spore fanout children/ \
  --bind-service metadata=unix:/tmp/metadata.sock
```

`spore checkpoint fork` still only mints child checkpoint directories; live
host socket paths are not written into child manifests.

When the parent has a proof-validated local `ram.backing` file, `spore
checkpoint fork` keeps the proven parent fd open across the batch, hard-links
that file into each child, and writes a child-local `ram.backing.proof`. Each child link is reopened
without following symlinks and must match the proof-bound parent file identity
before the proof is written. A missing or stale parent proof, an unavailable
hard-link capability, or a conflicting child proof produces a chunk-only child;
identity races and unexpected I/O abort the fork. `spore fanout` does not need a
trust flag or special mode: each child uses normal product attach (`spore
attach`, or `spore run --from` for run/rootfs children), which maps local
backing only when the proof validates and otherwise restores from verified
chunks.

The batch directory is the movement and ownership boundary. Child `chunks`
links are batch-relative (`../shared-chunks`), so moving the complete batch
preserves RAM authority. Moving or deleting one child does not transfer or
clean up the shared store; use pack/unpack when a child must be independently
portable.

Each disk-backed child gets its own durable disk pin, so removing the parent or
a sibling cannot release that child's disk state. The child still reports
`batch-relative` because its RAM chunks belong to the batch. Raw copies are not
valid ownership transfers; use `spore clone` for an independently removable
portable child or another fork for a machine-local lifetime.

For pinned disk-backed batches, human and JSON fork results report cache-lock
wait separately from the lock-held pin and batch publication interval. These
timings make contention distinct from the short publication critical section.

## Local Child Identity

For a local fork batch, each child records explicit Buildkite-shaped SporeVM
identity:

```text
SPORE_PARALLEL_JOB=0
SPORE_PARALLEL_JOB_COUNT=5
```

through:

```text
SPORE_PARALLEL_JOB=4
SPORE_PARALLEL_JOB_COUNT=5
```

Inside run/rootfs guests, the initrd agent publishes the generation payload at
`/run/sporevm/generation.json` plus env-style helper lines in
`/run/sporevm/env`:

```text
SPORE_PARALLEL_JOB=0
SPORE_PARALLEL_JOB_COUNT=5
SPORE_GENERATION=42
SPORE_PARENT_GENERATION=41
SPORE_VM_ID=spore-...
SPORE_FORK_BATCH_ID=...
SPORE_RESUME_TIME_UNIX_NS=...
```

The generation JSON also includes `parallel_index`, `parallel_count`,
`fork_index`, `fork_count`, `fork_batch_id`, `vm_id`, `generation`,
`parent_generation`, and resume-time fields minted when a child actually
resumes. `fork_index` and `fork_count` are batch-local metadata and match the
parallel fields for this local-only slice. Do not infer global shard positions
from these fields.

For live saves, already-running processes do not get a new environment block
on attach. `/run/sporevm` is a runtime metadata surface backed by guest runtime
state, not rootfs image content; a live save can contain older files until the
guest agent refreshes them from the generation device. Workloads that need
shard identity must read `/run/sporevm/env` or `/run/sporevm/generation.json`
after fan-out and wait for child generation metadata before starting sharded
work. For a parent saved before `spore fork`, a practical barrier is to
require `SPORE_FORK_BATCH_ID`, `SPORE_PARALLEL_JOB`,
`SPORE_PARALLEL_JOB_COUNT`, and `SPORE_GENERATION >
SPORE_PARENT_GENERATION`. Harnesses that can read the child manifest can compare
the exact expected generation.

The guest agent mixes the resume-time entropy seed into the kernel RNG before a
forked `spore run --from` command starts. Live-forked processes can still carry
process-local RNG state copied from the parent, so entropy-sensitive workloads
must reexec, reseed their own runtime, or wait behind an application-level
after-restore hook before generating secrets.

`spore fanout` orchestrates child attaches and prefixes output. It does not prove
that arbitrary already-running workloads consumed the metadata; workload
harnesses own the identity-before-work barrier. `spore run --from` remains the
completed-base path for starting a fresh command inside a child spore.

Automation can replace prefixed human output with the shared event contract:

```bash
spore fanout children --for 10s --events=jsonl
```

Each stdout or stderr record carries the child directory name in `child`, its
per-stream byte `offset` and `byte_count`, and base64 bytes in `data_base64`.
Every child then emits `child_completion`; a non-zero guest exit remains a
completed child result and sets the aggregate process status. The aggregate
stream ends with one `spore.automation.event.v1` completion record, while an
abnormal child termination produces a failed aggregate completion instead of
requiring callers to infer status from EOF or prefixed diagnostics. See
[Automation contract](automation.md).

## Single-Child Resume Identity

Fleet adapters that materialize one child can inject the same guest-visible
identity surface without running local fan-out. Use `spore run --from` when the
child should run a fresh one-shot command:

```bash
spore run --from child.spore \
  --generation generation.json \
  -- ./bin/test-one-shard
```

Use `spore attach` when the child should resume an already-saved session:

```bash
spore attach child.spore \
  --generation generation.json \
  --events=jsonl
```

`generation.json` is copied through the existing generation resume path and the
guest agent publishes it before the command or attached session starts at
`/run/sporevm/generation.json`, with compatible helper lines in
`/run/sporevm/env`. The payload must be a JSON object with
`run_id`, `child_id`, `parallel_index`, `parallel_count`, `fork_index`,
`fork_count`, `fork_batch_id`, and `vm_id`. Counts must be positive, and index
values must be smaller than their matching counts. The interface is generic:
SporeVM treats these as fan-out identity fields, not Rails, CI, or Kubernetes
policy.
