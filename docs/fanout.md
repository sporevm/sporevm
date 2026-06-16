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
SPORE_VM_ID=spore-...
SPORE_FORK_BATCH_ID=...
```

The generation JSON also includes `parallel_index`, `parallel_count`,
`fork_index`, `fork_count`, `fork_batch_id`, and `vm_id`. `fork_index` and
`fork_count` are batch-local metadata and match the parallel fields for this
local-only slice. Do not infer global shard positions from these fields.
