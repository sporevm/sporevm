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
scripts/benchmark/suite.py --profile smoke
scripts/benchmark/suite.py --profile ci
scripts/benchmark/suite.py --profile comparison
scripts/benchmark/suite.py --profile nightly
scripts/benchmark/suite.py --profile full
```

- `smoke`: one sequential iteration plus a tiny warm/distribution pass and one
  package-style writable-rootfs pass.
- `ci`: short cold and warm TTI sequential/burst runs, suitable for regular CI
  artifacts.
- `comparison`: small sequential and burst runs plus one SQLite and
  package-style writable-rootfs pass, suitable for post-merge, manual, or
  nightly comparison artifacts.
- `nightly`: scheduled guardrail profile with five sequential samples of warm
  `spore run --image`, synthetic cold rootfs import, fork timing, and
  distribution save/restore, plus one package-style writable-rootfs pass. This
  is the profile used for regression detection on Buildkite schedules.
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

CI benchmark builds (`scripts/ci/buildkite-benchmarks.sh`, triggered from the
main pipeline) default to `public.ecr.aws/docker/library/node:22-alpine` with
the suite's default `node -v` first command, on every branch. This keeps the
published trends like-for-like with the public
[ComputeSDK sandbox TTI benchmark](https://www.computesdk.com/benchmarks/sandboxes/)
(node runtime, `node -v` as the timed first command) while sourcing the image
from the AWS public ECR mirror of Docker Official Images instead of Docker Hub,
which rate-limits anonymous CI pulls. Scheduled builds run the `nightly`
profile, main-triggered builds run `comparison`, and other branches run `ci`.
Override with
`SPOREVM_BENCHMARK_IMAGE`, `SPOREVM_BENCHMARK_COMMAND`, and
`SPOREVM_BENCHMARK_PROFILE`.

Every published series point records its `profile` and `sample_count`, so
consumers can separate scheduled guardrail points from small-N per-merge
`comparison` points that share a `benchmark/mode` series.

Benchmark builds use the shipped `--release=safe` settings (`mise run
build:release`); a default Debug `zig build` understates TTI by roughly 40
percent and must not feed published trends. The suite records
`spore version` output (which includes the optimize mode) in each run's
config so build-mode changes are attributable in the series.

## Benchmarks

### Named Restore Readiness

Use an immutable saved parent to measure the persistent named path separately
from one-shot `run --from`:

```console
scripts/benchmark/named-restore-readiness.py --spore-dir parent.spore
```

The benchmark builds SporeVM in ReleaseSafe mode unless `--no-build` is passed.
Each JSONL row records CLI restore-return wall time, the observed exec-ready
point and its source, the machine-reported exec-ready wait and total, the first
`/bin/true` exec, repeated no-op exec samples and median, and cleanup time. The
input spore is only read and can be reused across iterations.

Pass `--include-run-from` to also record one-shot `run --from ... /bin/true`
wall time against the same parent and host.

### Cold TTI

Cold TTI follows the ComputeSDK benchmark shape: the timer starts before
`spore run` creates the sandbox and stops when the `spore run` process exits
after the command completes.

```text
spore run --image node@sha256:... --memory 512mb -- /usr/local/bin/node -v
```

This path works on both KVM and HVF today. It is the apples-to-apples startup
number for sandbox-provider comparisons.

With the default prewarm enabled, `cold_tti` is also the guardrail for warm
`spore run --image`: the rootfs has already been built outside the timed loop,
so the timed rows measure the cached image run path that regressed in PR #421.

### Lazy Rootfs TTI

Use `lazy_rootfs_tti` to compare first-command readiness from the same complete
chunked image cache in three storage states:

```console
scripts/benchmark/suite.py \
  --profile smoke \
  --benchmarks lazy_rootfs_tti \
  --iterations 3 \
  --modes sequential \
  --image local/example:dev
```

- `lazy-cold` removes the derived flat artifact and faults CAS chunks as the
  guest reads them.
- `eager-cold` removes the flat artifact and materializes it completely from
  the warm CAS before boot.
- `flat-hot` reuses the eager run's derived flat artifact.

The benchmark accepts registry `@sha256` identities and native local
`@blake3` identities. It selects cache metadata by the exact resolved image, so
it never evicts an unrelated image's flat artifact. Native `spore build`
outputs may be chunk-only and have no source flat path; the eager row creates
the flat artifact that the following hot row uses.

Each timed run requests a rootfs trace. Lazy rows must emit exactly one
versioned `lazy_cas_fault_summary`, report zero fault errors, and fault at least
one CAS chunk. `SPOREVM_ROOTFS_TRACE_SUMMARY_ONLY=1` suppresses per-read events
so measurement does not add one trace write per fault. The row and summary
include runtime-open and index-attach time, exact owned index payload bytes,
initial and remaining CAS chunks, fault count and bytes, working-set
percentage, and cumulative object preparation, read, verification, sparse
write, and unclassified fault-service time. The trace contains no paths or
digests.

### Cold Import

Cold import measures deterministic rootfs materialization without depending on
the `buildkite-sporevm` image or any registry:

```text
generate synthetic rootfs tar
spore rootfs import-tar rootfs.tar --ref local/sporevm-benchmark-synthetic:nightly
```

The suite creates a byte-identical tar from a fixed seed and imports it into a
fresh per-iteration rootfs cache with `SPOREVM_ROOTFS_BUILD_PROFILE=1`. The
default fixture is topology-realistic rather than flat: thousands of nested
directories, many payload files per leaf directory, hardlinks, and symlinks,
with a small data payload so it still fits the nightly budget.

Each `cold_import/synthetic_tar` row stores `elapsed_ms`/`tti_ms`,
`rootfs_import_index_digest`, and rootfs profile phase counters such as
`rootfs_profile_native_ext4_emit_assign_ms`,
`rootfs_profile_rootfs_cas_inline_objects_written`, chunk counts, object bytes,
and native writer emit counters. The digest is expected to remain stable across
runs because the tar fixture is deterministic.

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
scripts/benchmark/writable-rootfs.sh --no-build --output writable-rootfs.jsonl
```

The suite adapts that JSONL into the same summary and comparison format as the
TTI rows. Each workload/mode pair becomes a comparable result, for example:

- `writable_rootfs/sqlite:cow-active-capture`
- `writable_rootfs/sqlite:sealed-layer-append`
- `writable_rootfs/sqlite:sealed-layer-replay`
- `writable_rootfs/package-install:cow-active-capture`
- `writable_rootfs/package-install:sealed-layer-append`
- `writable_rootfs/package-install:sealed-layer-replay`

For the Kubernetes parent-preparation shape specifically, use:

```console
scripts/benchmark/hot-run-save.sh --spore-bin zig-out/bin/spore --backend kvm
```

This prewarms `node:22-bookworm-slim`, then times fresh
`spore run --image ... --save ... --save-on USR1` captures triggered by the
same stdout marker used by the public Kubernetes runtime. Each capture records
the disk snapshot metrics. The benchmark fails if a hot capture performs a
full logical-rootfs scan instead of sealing only dirty chunks; use
`--allow-full-scan` only when comparing historical binaries that predate the
guardrail. Performance claims from this benchmark require a ReleaseSafe binary
on Linux ARM64/KVM.

The timed value is the product-path command duration from the underlying script,
stored in the suite's existing `tti_ms` summary field so the same comparator can
catch regressions. These rows answer "what does writable rootfs capture, append,
and replay cost?" rather than only "how fast is first output?"

Profile defaults keep this bounded because writable-rootfs work is much heavier
than the Node startup loops. Override with:

```console
scripts/benchmark/suite.py \
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
scripts/benchmark/memory-throughput.py --iterations 5
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
scripts/benchmark/compare.py baseline-summary.json candidate-summary.json
```

Defaults fail when:

- median TTI regresses by more than 20 percent and at least 50ms;
- p95 regresses by more than 30 percent and at least 50ms;
- p99 regresses by more than 40 percent and at least 50ms;
- success rate drops by more than 2 percentage points.

Thresholds are flags so CI can tighten release gates without changing the
benchmark data format.

## Regression Detection

Scheduled Buildkite benchmark jobs also run:

```console
scripts/benchmark/detect_regressions.py \
  zig-cache/sporevm-benchmarks/latest-summary.json \
  --history-dir zig-cache/sporevm-benchmarks/history \
  --markdown-out zig-cache/sporevm-benchmarks/regression-report.md \
  --json-out zig-cache/sporevm-benchmarks/regression-report.json
```

The detector compares the current run's per-metric minimum against the minimum
from a trailing window of prior runs on the same `host_id`. It uses history from
downloaded Buildkite artifacts when available. Non-scheduled runs tolerate empty
or missing history so developers can run the same script locally. Scheduled
Buildkite runs fail when no compatible same-host history exists unless the
current run declares an intentional reset with `SPOREVM_BENCHMARK_RESET` or a
`spore-benchmark-reset:` commit-message line. The failure annotation points at
the likely causes: artifact fetch failure, `host_id` drift, or a fresh pipeline
that needs an intentional bootstrap.

The detector also checks durable absolute ceilings from
`benchmarks/expectations.json`. A metric that exceeds its `max` value fails even
when the rolling trailing window has already ratcheted up to the same slower
value. These ceilings are the long-lived floor for headline guardrail metrics
and should be changed deliberately in PRs, unlike the rolling baseline that is
refreshed from scheduled artifacts.

Thresholds are metric-class based:

- latency metrics such as warm image TTI, warm spore TTI, fork latency,
  `vsock_connect_ms`, and `exec_response_ms`: warn above 30 percent, fail above
  60 percent;
- throughput/import metrics such as synthetic cold import, rootfs emit phases,
  and batch wall times: warn above 10 percent, fail above 20 percent;
- counter metrics such as rootfs objects, chunks, bytes, and block counts: warn
  on any change, fail when an increase reaches 2x or moves from zero to nonzero.
- digest metrics such as `cold_import/synthetic_tar/rootfs_import_index_digest`:
  fail on any change against compatible history;
- success-rate metrics derived from raw benchmark rows before failed rows are
  filtered: warn on any decrease, and fail when a benchmark with a 100 percent
  baseline drops below 100 percent.

The Buildkite annotation table shows the current value, trailing baseline, delta,
verdict, number of history runs used, and threshold for each metric. `warning`
annotations keep the build green; `error` annotations come from fail-tier
verdicts and fail the benchmark job.

To run the same detector locally against saved benchmark directories:

```console
scripts/benchmark/detect_regressions.py \
  zig-cache/sporevm-benchmarks/latest-summary.json \
  --history-dir /path/to/prior/benchmark-artifacts
```

The loader accepts suite `latest-summary.json`, `summary.json`, `results.jsonl`,
run directories, and older ad hoc benchmark directories containing
`warm-run-true*.log` plus `system-df-rootfs.log`.

### Resetting History

Intentional benchmark changes should reset history instead of leaving a metric
red forever. For a durable reset, bump `benchmarks/expectations.json` in the
same PR:

```json
{
  "version": 1,
  "metrics": {
    "cold_import/synthetic_tar/rootfs_profile_rootfs_cas_inline_objects_written": {
      "reset": "2026-07-native-cas-layout",
      "reason": "CAS object layout changed intentionally"
    }
  }
}
```

Metric keys support exact names, `benchmark/mode`, and shell-style globs. When
the current expectation `reset` marker differs from history, older points are
ignored until new same-reset history accumulates.

Expectation entries can also carry absolute ceilings:

```json
{
  "version": 1,
  "metrics": {
    "cold_tti/sequential/tti_ms": {
      "max": 750,
      "reason": "Warm spore run --image TTI ceiling"
    }
  }
}
```

The ceiling check is independent of rolling history. Updating a ceiling should
be a deliberate PR review decision, and scheduled reset builds still check these
absolute limits even when there is no prior same-host history.

For a one-off reset, include a commit message line:

```text
spore-benchmark-reset: warm_spore_tti/*,cold_import/synthetic_tar/*
```

The reset build becomes the new baseline for matching metrics; the reset build
itself does not fail.

Rootfs digest changes should use the same reset path. For example, a deliberate
ext4 writer format change that updates the deterministic cold-import digest can
either bump the durable expectation marker:

```json
{
  "version": 1,
  "metrics": {
    "cold_import/synthetic_tar/*": {
      "reset": "2026-07-ext4-format-v2",
      "reason": "Intentional rootfs format change"
    }
  }
}
```

or use a one-off commit message line:

```text
spore-benchmark-reset: cold_import/synthetic_tar/rootfs_import_index_digest
```

The high-directory fixture introduced in July 2026 uses
`2026-07-topology-realistic-synthetic-rootfs` as its cold-import reset marker so
old flat-fixture history does not trip the first scheduled run.

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
scripts/benchmark/export-site-data.py \
  zig-cache/sporevm-benchmarks/latest-summary.json \
  --history public-benchmarks/data.json \
  --json-out public-benchmarks/data.json \
  --js-out public-benchmarks/data.js
```

Keep separate histories for different hardware classes or profiles. A `ci`
profile on a busy shared runner and a `full` profile on fixed Linux/KVM hardware
answer different questions.

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

The dedicated `sporevm-benchmarks` pipeline is launched manually in Buildkite.
The main `sporevm` pipeline does not trigger benchmark builds.

The dedicated benchmark pipeline runs macOS and Linux ARM64 benchmark jobs in
parallel on `sporevm-mac` and `sporevm-linux-arm64`. Each platform job uses a
per-platform concurrency group so two benchmark builds do not share the same
runner class at once. It defaults to `nightly` for Buildkite schedules,
`comparison` on `main`, and `ci` otherwise. Override with
`SPOREVM_BENCHMARK_PROFILE=ci` for a short cold/warm run, `nightly` for the
guardrail selection, or `full` when a build should pay for the full benchmark
matrix.

Before the timed suite starts, the CI wrapper logs the host load averages and
CPU count. Set `SPOREVM_BENCHMARK_MAX_LOADAVG_1M` to fail early when the
one-minute load average is too high for a trustworthy run.

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
run by hand with a narrower `--only` list.

Before the regression detector runs, the CI wrapper tries to download prior
`results.jsonl`, `config.json`, and `summary.json` artifacts from recent builds
of the same benchmark pipeline into `zig-cache/sporevm-benchmarks/history`. If
`BUILDKITE_API_TOKEN` is available, it resolves prior build UUIDs through the
Buildkite REST API before calling `buildkite-agent artifact download --build`.
Without that token it falls back to probing recent build numbers and tolerates
misses. Set `SPOREVM_BENCHMARK_HISTORY_DIR` to point at a local history
directory, or `SPOREVM_BENCHMARK_HISTORY_BUILDS` to change the number of prior
Buildkite builds probed. Missing artifact history is allowed; the detector
emits `no_history` rows and keeps non-scheduled builds green until comparable
history exists. Scheduled builds require at least one compatible same-host
history run unless the current run carries an intentional reset marker, so
artifact download failures or host-id drift do not silently disable the
guardrail.

Regardless of comparison result, the step exports `site/data.json` and
`site/data.js`, uploads benchmark JSON, logs, rootfs metadata, trend data,
`regression-report.md`, and `regression-report.json` as artifacts and S3
objects, and publishes Buildkite annotations summarizing both the latest
benchmark run and regression verdicts. Generated work directories, bundle
chunks, downloaded history, and rootfs chunk stores stay out of S3.
