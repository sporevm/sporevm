# SporeVM Benchmark Suite

The repeatable benchmark entrypoint is:

```console
mise run benchmark:ci
```

It writes raw JSONL, a summary JSON, logs, and a `latest-summary.json` pointer
under `zig-cache/sporevm-benchmarks/`. The output is designed for CI artifact
upload and later comparison.

Use `--scratch-dir PATH` when large benchmark work and caches should live on a
faster disk while durable output remains under `zig-cache/sporevm-benchmarks/`.

Export static trend data for dashboards with:

```console
mise run benchmark:export
```

That converts `latest-summary.json` into:

- `zig-cache/sporevm-benchmarks/site/data.json`
- `zig-cache/sporevm-benchmarks/site/data.js`
- `zig-cache/sporevm-benchmarks/site/homepage-summary.json`
- `zig-cache/sporevm-benchmarks/site/homepage-summary.js`

The JavaScript artifact assigns `window.SPOREVM_BENCHMARK_DATA`, so a static
page can render the latest run plus any retained history without learning the
runner's raw artifact layout. The homepage summary assigns
`window.SPOREVM_HOMEPAGE_BENCHMARK_DATA` and contains a small homepage-focused
projection: public runner labels, default-runner latest metrics/history, and
per-runner latest metrics/history for the public macOS and Linux ARM64 options.

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

TTI profiles default to `--memory 512mb` so startup comparisons measure the hot
launch path rather than the first-slice `auto` memory contract. Pass
`--memory auto` when intentionally measuring the 16GiB automatic-memory path.

## CI Defaults

CI benchmark builds (`scripts/ci-buildkite-benchmarks.sh`, triggered from the
main pipeline) default to `public.ecr.aws/docker/library/node:22-alpine` with
the suite's default `node -v` first command, on every branch. This keeps the
published trends like-for-like with the public
[ComputeSDK sandbox TTI benchmark](https://www.computesdk.com/benchmarks/sandboxes/)
(node runtime, `node -v` as the timed first command) while sourcing the image
from the AWS public ECR mirror of Docker Official Images instead of Docker Hub,
which rate-limits anonymous CI pulls. Main builds run the `comparison` profile;
other branches run `ci`. A nightly Buildkite schedule on the
`sporevm-benchmarks` pipeline runs the `full` profile (the exact public shape:
100 iterations, sequential/staggered/burst) by setting
`SPOREVM_BENCHMARK_PROFILE=full`, so the published series carry statistically
robust p95/p99 alongside the per-merge regression points. Override with
`SPOREVM_BENCHMARK_IMAGE`, `SPOREVM_BENCHMARK_COMMAND`, and
`SPOREVM_BENCHMARK_PROFILE`.

Every published series point records its `profile` and `sample_count`, so
consumers can separate high-iteration nightly `full` points from small-N
per-merge `comparison` points that share a `benchmark/mode` series.

Benchmark builds use the shipped `--release=safe` settings (`mise run
build:release`); a default Debug `zig build` understates TTI by roughly 40
percent and must not feed published trends. The suite records
`spore version` output (which includes the optimize mode) in each run's
config so build-mode changes are attributable in the series.

## Benchmarks

### Cold TTI

Cold TTI follows the ComputeSDK benchmark shape: the timer starts before
`spore run` creates the sandbox and stops when the `spore run` process exits
after the command completes.

```text
spore run --image node@sha256:... --memory 512mb -- /usr/local/bin/node -v
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

Defaults fail when:

- median TTI regresses by more than 20 percent and at least 50ms;
- p95 regresses by more than 30 percent and at least 50ms;
- p99 regresses by more than 40 percent and at least 50ms;
- success rate drops by more than 2 percentage points.

Thresholds are flags so CI can tighten release gates without changing the
benchmark data format.

## Publishing Trends

The export format is intentionally small: each run records commit and runner
metadata, benchmark profile, backend, image, memory, and lower-is-better median
timings for every summarized hot path. It also includes pre-shaped series keyed
as `benchmark/mode`, such as `cold_tti/sequential` or
`warm_spore_tti/burst`.

Each run result carries the successful raw timing `samples` used for its
aggregate stats, with failures represented by `success_count` and
`success_rate`. Each series point carries median `value`, `p95`, `p99`, success
rate, commit, branch, and Buildkite build number. Runs also include host context
(`os`, `arch`, `kernel`, CPU model/count, memory, load average, and disk space)
so public charts can distinguish product movement from runner noise.

When the underlying `spore run` logs expose phase timings, the suite summarizes
them under `phase_metrics` and exports median phase values on each series point.
Currently that includes rootfs open, backend restore/pre-run,
backend run/tail, vsock connect, exec response, first output, and exec-probe
timing slices. KVM runs also export probe-completion timing, and guest timing
frames expose listen, request accept/decode, spawn, and exit slices.

Append to an existing published history with:

```console
scripts/export-sporevm-benchmark-data.py \
  zig-cache/sporevm-benchmarks/latest-summary.json \
  --history public-benchmarks/data.json \
  --json-out public-benchmarks/data.json \
  --js-out public-benchmarks/data.js
```

Keep separate histories for different hardware classes or profiles. A `ci`
profile on a busy shared runner and a `full` profile on fixed A1 hardware answer
different questions.

Buildkite publishes the website projection to:

```text
s3://sporevm-benchmarks/site/data.json
s3://sporevm-benchmarks/site/data.js
s3://sporevm-benchmarks/site/homepage-summary.json
s3://sporevm-benchmarks/site/homepage-summary.js
```

Only successful `main` benchmark builds update those files. The publisher merges
the macOS and Linux ARM64 per-build exports, canonicalizes run IDs by
build/commit/platform, and keeps the chart series split by runner queue so the
website can show `main` progress without mixing hardware classes.
The writer role needs `GetObject` for those exported per-build files and
`PutObject` for `site/data.json`, `site/data.js`, and the homepage summary
files.

## Buildkite

The main Buildkite pipeline triggers the dedicated `sporevm-benchmarks` pipeline
on `main` after merge with the short `ci` profile. Non-main builds can opt in
with:

```console
SPOREVM_RUN_BENCHMARKS=1
```

The dedicated benchmark pipeline runs macOS and Linux ARM64 benchmark jobs in
parallel on `sporevm-mac` and `sporevm-linux-arm64`. It defaults to the
broader `comparison` profile for manual runs. Override with
`SPOREVM_BENCHMARK_PROFILE=ci` for a short cold/warm run, or `full` when a build
should pay for the full benchmark matrix.

The CI wrapper honors `SPOREVM_BENCHMARK_SCRATCH_ROOT` when set. Otherwise it
uses `/var/tmp/nvme/sporevm-benchmarks` when that prepared path exists and is
writable, falling back to the checkout disk.

The benchmark steps live in `.buildkite/pipeline.benchmarks.yaml`. A standalone
Buildkite pipeline can use this repository with this upload command:

```console
buildkite-agent pipeline upload .buildkite/pipeline.benchmarks.yaml
```

That dedicated pipeline also uploads durable benchmark data to:

```text
s3://sporevm-benchmarks/builds/${BUILDKITE_BUILD_NUMBER}/${BUILDKITE_COMMIT}/macos/
s3://sporevm-benchmarks/builds/${BUILDKITE_BUILD_NUMBER}/${BUILDKITE_COMMIT}/linux-arm64/
```

After both benchmark jobs finish on `main`, a serialized publish step rebuilds
and uploads the stable website files under `s3://sporevm-benchmarks/site/`.

If `SPOREVM_BENCHMARK_BASELINE` points to a summary JSON available in the job
workspace, the step compares the new `latest-summary.json` against that
baseline. Baselines should come from the same profile unless the comparator is
run by hand with a narrower `--only` list. Regardless of comparison result, the
step exports `site/data.json` and `site/data.js`, uploads benchmark JSON, logs,
rootfs metadata, and trend data as artifacts and S3 objects, and publishes a
Buildkite annotation summarizing the latest benchmark run. Generated work
directories, bundle chunks, and rootfs chunk stores stay out of S3.
