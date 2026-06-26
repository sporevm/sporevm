# SporeVM Benchmark Suite

The repeatable benchmark entrypoint is:

```console
mise run benchmark:ci
```

It writes raw JSONL, a summary JSON, logs, and a `latest-summary.json` pointer
under `zig-cache/sporevm-benchmarks/`. The output is designed for CI artifact
upload and later comparison.

## Profiles

```console
scripts/benchmark-sporevm-suite.py --profile smoke
scripts/benchmark-sporevm-suite.py --profile ci
scripts/benchmark-sporevm-suite.py --profile comparison
scripts/benchmark-sporevm-suite.py --profile full
```

- `smoke`: one sequential iteration plus a tiny warm/distribution pass and one
  package-style writable-rootfs pass.
- `ci`: short cold and warm TTI sequential/burst runs, suitable for regular CI
  artifacts.
- `comparison`: small sequential and burst runs plus one SQLite and
  package-style writable-rootfs pass, suitable for post-merge, manual, or
  nightly comparison artifacts.
- `full`: 100-way sequential, staggered, and burst runs matching the public TTI
  shape, plus three writable-rootfs iterations per workload.

All profiles use a digest-pinned image. If `--image` is a mutable tag, the suite
resolves it once before timed benchmark loops so registry tag lookup is not
mixed into TTI. By default the suite also performs an untimed
`spore run --image ... -- /bin/true` prewarm so rootfs cache misses and
OCI-to-ext4 materialization are not mixed into TTI. Pass `--no-prewarm-rootfs`
when intentionally measuring the full cold image path.

## Benchmarks

### Cold TTI

Cold TTI follows the ComputeSDK benchmark shape: the timer starts before
`spore run` creates the sandbox and stops when the `spore run` process exits
after the command completes.

```text
spore run --image node@sha256:... --memory auto -- /usr/local/bin/node -v
```

This path works on both KVM and HVF today. It is the apples-to-apples startup
number for sandbox-provider comparisons.

### Warm Spore TTI

Warm Spore TTI measures the differentiated path:

```text
capture base spore once
fork N child spores
spore run --from child -- /usr/local/bin/node -v
```

Base capture and fork timing are recorded as setup rows. Per-child `tti_ms`
measures resume-to-first-command from pre-forked child state.

### Distribution TTI

Distribution TTI measures local materialization plus first command:

```text
spore pack base.spore --children children --out bundle
spore pull file://bundle --child N --out pulled/N
spore run --from pulled/N -- /usr/local/bin/node -v
```

Per-child `tti_ms` includes pull plus resume/exec. Rows also include pull metrics
from `spore pull`, such as chunk/rootfs bytes fetched, chunk/rootfs bytes reused,
and cache hits. The smoke, comparison, and full profiles run this sequentially
by default; pass `--include-distribution-concurrency` to run selected
staggered/burst modes too.

### Writable Rootfs

Writable rootfs benchmarks wrap the product-path helper:

```text
scripts/benchmark-writable-rootfs.sh --no-build --output writable-rootfs.jsonl
```

The suite adapts that JSONL into the same summary and comparison format as the
TTI rows. Each workload/mode pair becomes a comparable result, for example:

- `writable_rootfs/sqlite:cow-active-capture`
- `writable_rootfs/sqlite:sealed-layer-append`
- `writable_rootfs/sqlite:sealed-layer-replay`
- `writable_rootfs/package-install:cow-active-capture`
- `writable_rootfs/package-install:sealed-layer-append`
- `writable_rootfs/package-install:sealed-layer-replay`

The timed value is the product-path command duration from the underlying script,
stored in the suite's existing `tti_ms` summary field so the same comparator can
catch regressions. These rows answer "what does writable rootfs capture, append,
and replay cost?" rather than only "how fast is first output?"

Profile defaults keep this bounded because writable-rootfs work is much heavier
than the Node startup loops. Override with:

```console
scripts/benchmark-sporevm-suite.py \
  --benchmarks writable_rootfs \
  --writable-rootfs-iterations 3 \
  --writable-rootfs-workloads sqlite,package
```

### Memory Economics

The suite emits a `memory_economics` row for the base spore. It records:

- configured RAM bytes;
- chunk size and chunk counts;
- zero-elided chunk count;
- chunk-store bytes;
- `ram.backing` logical and allocated bytes when present;
- immutable rootfs artifact size when present.

This is intentionally separate from TTI. TTI answers "how fast is it
interactive?" Memory economics answers "what did that logical VM state cost?"

### Memory Throughput

Use the standalone memory-throughput probe when the question is guest copy speed
rather than startup time:

```console
scripts/benchmark-memory-throughput.py --iterations 5
```

It runs the same Node `Buffer.copy` workload natively and through one-shot
`spore run`. Each row records the guest-reported copy time and the host wall
time separately, so lifecycle overhead is visible instead of blended into the
throughput number. Add `--environments native,spore_run,spore_exec` when the
local monitor lifecycle path is the thing being measured.

## Modes

- `sequential`: one child at a time.
- `staggered`: concurrent launches spaced by `--stagger-delay-ms`.
- `burst`: concurrent launches submitted without intentional delay.

Each per-iteration row includes `tti_ms`, `success`, `status`, launch/start/end
offsets, and log paths. Batch rows include `wall_clock_ms` and
`time_to_first_ready_ms`.

## Comparing Results

Compare two summary files with:

```console
scripts/compare-sporevm-benchmarks.py baseline-summary.json candidate-summary.json
```

## Substrate Snapshot Comparison

The public Substrate snapshot page measures restore start to the first in-guest
vsock reply. The closest SporeVM product-path comparison is resumed child
`exec_response_ms` from `spore run --events=jsonl --from child -- /bin/true`.

```console
mise run benchmark:substrate-snapshot
```

For a quick 2 GiB local check:

```console
scripts/benchmark-substrate-snapshot.py --memory-mib 2048 --iterations 1
```

This fetches the latest `https://benchmarks.substrate.so/<arch>/data.js`, runs
matching RAM sizes, and writes JSONL plus `summary.json` under
`zig-cache/sporevm-substrate-snapshot/`. Restore rows fail by default unless the
child used proof-backed local RAM with backend `mode=local_backing` and
`MAP_PRIVATE` file-backed memory. The summary reports both the existing
`exec_response_ms` and `backend_pre_run_ms + exec_response_ms`, which is the
closer restore-to-first-reply comparison.

Defaults fail when:

- median TTI regresses by more than 20 percent and at least 50ms;
- p95 regresses by more than 30 percent and at least 50ms;
- p99 regresses by more than 40 percent and at least 50ms;
- success rate drops by more than 2 percentage points.

Thresholds are flags so CI can tighten release gates without changing the
benchmark data format.

## Buildkite

The Buildkite benchmark step runs automatically on `main` after merge. Non-main
builds can opt in with:

```console
SPOREVM_RUN_BENCHMARKS=1
```

It runs on `cleanroom-mac` by default so the suite has a supported HVF backend,
and defaults to the broader `comparison` profile. Override with
`SPOREVM_BENCHMARK_PROFILE=ci` for a short cold/warm run, or `full` when a build
should pay for the full benchmark matrix.

If `SPOREVM_BENCHMARK_BASELINE` points to a summary JSON available in the job
workspace, the step compares the new `latest-summary.json` against that
baseline. Baselines should come from the same profile unless the comparator is
run by hand with a narrower `--only` list. Regardless of comparison result, the
step uploads benchmark JSON, logs, and rootfs metadata as artifacts and publishes
a Buildkite annotation summarizing the latest benchmark run.
