# Fan-Out

`spore fork` mints local child spores, and `spore fanout` resumes those children
with prefixed output:

```bash
spore fork warm.spore --count 5 --out children/
spore fanout children/ --parallel
```

Children are named `000000` through zero-padded `N-1` and share the parent's
chunk store. `spore fanout` is local orchestration over child spore directories;
distributed offset/range partitioning is deferred.

When the parent has a proof-validated local `ram.backing` file, `spore fork`
hard-links that file into each child and writes a child-local
`ram.backing.proof`. If the parent proof is missing or stale, children omit
backing metadata and resume from chunks. `spore fanout` does not need a trust
flag or special mode: each child uses normal product restore (`spore resume`, or
`spore run --from` for run/rootfs children), which maps local backing only when
the proof validates and otherwise restores from verified chunks.

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

For live captures, already-running processes do not get a new environment block
on resume. `/run/sporevm` is a runtime metadata surface backed by guest runtime
state, not rootfs image content; a live snapshot can contain older files until
the guest agent refreshes them from the generation device. Workloads that need
shard identity must read `/run/sporevm/env` or `/run/sporevm/generation.json`
after fan-out and wait for child generation metadata before starting sharded
work. For a parent captured before `spore fork`, a practical barrier is to
require `SPORE_FORK_BATCH_ID`, `SPORE_PARALLEL_JOB`,
`SPORE_PARALLEL_JOB_COUNT`, and `SPORE_GENERATION >
SPORE_PARENT_GENERATION`. Harnesses that can read the child manifest can compare
the exact expected generation.

The guest agent mixes the resume-time entropy seed into the kernel RNG before a
forked `spore run --from` command starts. Live-forked processes can still carry
process-local RNG state copied from the parent, so entropy-sensitive workloads
must reexec, reseed their own runtime, or wait behind an application-level
after-restore hook before generating secrets.

`spore fanout` orchestrates child resumes and prefixes output. It does not prove
that arbitrary already-running workloads consumed the metadata; workload
harnesses own the identity-before-work barrier. `spore run --from` remains the
completed-base path for starting a fresh command inside a child spore.

## Single-Child Resume Identity

Fleet adapters that materialize one child and call `spore resume` directly can
inject the same guest-visible identity surface without running local fan-out:

```bash
spore resume child.spore --generation generation.json --events=jsonl
```

`generation.json` is copied through the existing generation attach path and the
guest agent publishes it at `/run/sporevm/generation.json`, with compatible
helper lines in `/run/sporevm/env`. The payload must be a JSON object with
`run_id`, `child_id`, `parallel_index`, `parallel_count`, `fork_index`,
`fork_count`, `fork_batch_id`, and `vm_id`. Counts must be positive, and index
values must be smaller than their matching counts. The interface is generic:
SporeVM treats these as fan-out identity fields, not Rails, CI, or Kubernetes
policy.
