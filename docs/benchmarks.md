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

Dedicated CI benchmark builds (`scripts/ci/buildkite-benchmarks.sh`) default to
`public.ecr.aws/docker/library/node:22-alpine` with the suite's default
`node -v` first command, on every branch. This keeps the
published trends like-for-like with the public
[ComputeSDK sandbox TTI benchmark](https://www.computesdk.com/benchmarks/sandboxes/)
(node runtime, `node -v` as the timed first command) while sourcing the image
from the AWS public ECR mirror of Docker Official Images instead of Docker Hub,
which rate-limits anonymous CI pulls. Scheduled builds run the `nightly`
profile, builds of `main` run `comparison`, and other branches run `ci`.
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

### `spore build` Rootfs Capacity

Run the user-facing paired gate and the separately labelled engineering control
from the repository root:

```console
scripts/benchmark/spore-build-rootfs-capacity.py \
  --spore "$PWD/zig-out/bin/spore" \
  --paired-matrix \
  --paired-profile default-path \
  --iterations 5 \
  --work-dir /path/to/default-work \
  --raw-output /path/to/default.jsonl \
  --output /path/to/default-summary.json

scripts/benchmark/spore-build-rootfs-capacity.py \
  --spore "$PWD/zig-out/bin/spore" \
  --paired-matrix \
  --paired-profile instrumented \
  --iterations 5 \
  --work-dir /path/to/instrumented-work \
  --raw-output /path/to/instrumented.jsonl \
  --output /path/to/instrumented-summary.json
```

The default profile uses literal product-path commands without debug or growth
experiment controls. It pairs cold preparation, warm, one-COPY incremental, and
shared-PREPARE `--no-cache` scenarios against an independently pre-grown lane.
Both lanes start from the same cloned compact parent and expose the same exact
16 GiB geometry; the measured control build must contain no PREPARE record.
The independent `run --commit` conditioning step takes its own snapshot, so its
index is not required to be byte-identical to the build PREPARE child.

The instrumented profile records preparation timing, boot counts, and storage
counters; add `--measure-rss` when host peak RSS is also required. Its results
never substitute for the default-path cold, warm, or incremental gates. P0-only
modes such as `force-fallback` and `checksum-lazy` are engineering negative
controls, not user configuration.

Before timing, the harness runs an untimed checkout-local ReleaseSafe build and
requires `--spore` to resolve to that checkout's `zig-out/bin/spore`. The
summary records repository HEAD and dirty/worktree identity; resolved binary
path, SHA-256, size, and version before and after the matrix; OS, architecture,
kernel, inferred backend, and an anonymized stable host descriptor. JSONL
command rows embed bounded stdout/stderr text together with byte counts, hashes,
and truncation state, so retained raw evidence does not depend on the
disposable work directory.

The command exits nonzero for provenance drift, incomplete or invalid trials,
insufficient samples, output/identity violations, or a failed aggregate gate.
Treat only a zero exit with five complete pairs as release evidence.

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
input spore is only read and can be reused across iterations. Rows also expose
`restore_source`, `restore_ram_mib`, and the backend's `memory_ms`, `state_ms`,
and `pre_run_ms` as `backend_memory_ms`, `backend_state_ms`, and
`backend_pre_run_ms`. This separates RAM materialization from the guest
readiness handshake instead of hiding both inside `wait_exec_ready_ms`.
Readiness rows also record connect-request delivery, connect completion,
request delivery, guest timing, response, and ready-publication milestones
from the monitor's structured timing file, so the evidence remains available
without enabling monitor debug logs.

Pass `--include-run-from` to also record one-shot `run --from ... /bin/true`
wall time against the same parent and host.

For release evidence, run the native wrapper on Linux ARM64/KVM and macOS
ARM64/HVF:

```console
scripts/ci/buildkite-named-restore-readiness.sh
```

The wrapper accepts only the repository-pinned v0.12.0 release identity. It
checks the downloaded checksum file before parsing it, checks that file's
platform archive entry against the pinned archive digest, checks the archive,
and checks the extracted executable byte-for-byte against its regular archive
member. The current checkout must be clean and match the expected full commit.
The current and historical binaries are recorded by version, size, and SHA-256,
and the requested and resolved image references are exact digests. Parent
manifest and proof files are SHA-256 hashed; RAM backing records stable device,
inode, owner, size, mtime, and allocation identity instead of reading and
hashing the 1 GiB file. Schema-v2 proofs additionally bind the backing's
fs-verity SHA-256 digest, while schema v1 makes no backing-content hash claim.
The managed kernel source is fixed to the checked-in
repository, release, version, Image, checksum-sidecar, and config digests; its
task-owned cache must match that closed identity exactly. Ambient `SPOREVM_*`
product settings are removed; runtime, rootfs, kernel, and temporary
directories are task-owned.
The checked-in image default is
`docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271`;
an override must also be an exact digest reference, so KVM and HVF cannot
independently resolve a moving tag.

Release mode is fixed at 1024 MiB, five rows per lane, and five repeated execs
per row. For each backend it covers current one- and two-vCPU parents in two
lanes: the proof key is present for `local_backing`, then absent in a fresh
runtime for deliberate `eager_chunks` with `reason=key_unavailable`. A separate
one-vCPU historical pair runs the v0.12.0 binary and the current binary against
the same v0.12.0 parent. The historical lane is separate because v0.12.0 did
not publish the current proof telemetry and its HVF multi-vCPU path did not
publish complete backend restore metrics. Its rows must still report the older
ready-publication timing and pass the full lifecycle, exec, and cleanup
contract, but they do not claim the six readiness phase fields introduced
after v0.12.0. Current-binary rows require every phase field.

Every current row must report one proof-validation line and one backend restore
line, and every current or tmpfs parent must report exactly one proof-write
line. Valid proof rows require `status=ok`, `source=local_backing`,
`reason=proof_valid`, the platform proof schema and verity mode, and
`memory_ms=0`: Linux current parents must use schema v2 with fs-verity SHA-256,
while macOS uses schema v1 with no verity. Deliberate fallback requires
`source=eager_chunks`, the expected reason, complete proof/backend timing, and
positive measured RAM materialization.
Every row must also satisfy the lifecycle readiness contract, exact requested
topology, successful first and repeated execs, and normal named cleanup. There
is no retry or waiver for the intermittent HVF two-vCPU repeated-exec failure.

Linux adds five-row controls on tmpfs for schema-v1/no-verity local backing and
missing-key eager fallback. The harness requires the control filesystem to
identify as `tmpfs`. A cross-filesystem fork must prove different source and
destination `st_dev`, omit local backing metadata, and restore through verified
chunks. Fan-out checks the parent validation plus every child proof write and
run-from validation, including schema, verity, source, reason, status, and
timing.

The Linux release lane ignores the general benchmark scratch setting and uses
a unique work directory beneath `SPOREVM_NAMED_RESTORE_SCRATCH_ROOT`, or
checkout-local `zig-cache` when that variable is absent. The selected location
must resolve to ext4, and before parent capture a disposable file must
successfully enable and measure fs-verity with SHA-256. The Linux opt-in job
sets the dedicated override to the host-provisioned, agent-writable task
scratch at `/var/tmp/sporevm-named-restore-verity`; `/dev/shm` remains the
deliberate tmpfs/schema-v1 control.

The macOS lane defaults its task scratch to `/tmp` rather than inheriting the
runner's potentially long `TMPDIR`. Both backends use a short work-directory
prefix, runtime aliases, and per-iteration VM names while retaining the full
scenario name in JSON evidence. Before each lane, the harness rejects any
generated `runtime/vms/<name>/control.sock` path longer than the portable
103-byte Unix-socket limit.

Correctness gates run before performance gates. Same-head median public restore
wall time, `restore_return_ms`, must be at least twice as fast with local backing
as with deliberate eager fallback for each backend and vCPU count. This field
is used because it is the public restore-to-ready API wall, including prepare,
monitor startup, and the readiness wait. The parent waits one millisecond
between each of the first ten readiness attempts, five milliseconds between the
next 100 attempts, and then twenty milliseconds between attempts during a long
failure. This bounds normal-start observation latency without permanently
increasing the timeout polling rate. Local backing must report zero backend RAM
materialization on every row; eager materialization must be positive but has no
upper threshold. Run-from, first-exec, and repeated-exec medians fail a
non-regression gate only when they are both more than 20 percent and at least
50 ms slower. Historical v0.12.0 comparison uses that non-regression rule but
does not substitute for the same-head local-versus-eager gate.

Python owns named cleanup and evidence generation. Parser failure, output
failure, timeout, SIGINT, and SIGTERM all run `spore rm`, verify the exact
runtime and monitor PID are gone, and require the task-owned active-lease set
to return exactly to its pre-restore state. Exact-PID and added-lease cleanup
are last-resort fallbacks and make a release row fail. The shell forwards
signals to the matrix child and waits until that cleanup has finished before
deleting scratch space. Public
command output is path-normalized before bounding and hashing, and the final
evidence object is normalized again before it is written.

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

`lazy_cas_index_payload_bytes` measures the live runtime representation, not
the canonical JSON index. Nonzero digests are one sorted array of raw BLAKE3
IDs shared by lazy faults and snapshot-parent reuse. The focused
`chunk_mapped_disk` ownership regression fixes the dense U7 case at 791,898
bytes in four allocations, down from 3,704,220 bytes in 38,075 allocations,
and covers sparse and all-zero indexes as well.

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
the disk snapshot metrics as a schema-versioned JSON object. The benchmark
fails if a hot capture performs a full logical-rootfs scan instead of sealing
only dirty chunks. `--allow-full-scan` permits a versioned full scan but does not
accept older, unversioned metric records. Performance claims from this
benchmark require a ReleaseSafe binary on Linux ARM64/KVM.

For repeated live checkpoints under a database write workload, use the opt-in
pgbench harness:

```console
mise run benchmark:pgbench-snapshot
```

The harness grows a PostgreSQL image before timing, initializes pgbench, adds a
per-client transactional commit counter to the standard TPC-B transaction, and
takes three non-destructive named saves while eight clients keep writing. Each
save records the existing disk, backend snapshot, and complete source-pause
metrics. A guest-side one-second counter sampler records the workload gap around
each save. Cadence is measured from one save start to the next; if a save itself
exceeds the interval, the following save starts as soon as the VM is available.
After the final checkpoint, the source workload is stopped and every checkpoint
is restored, quiesced, checked against the pre-save transaction lower bound,
and verified with `pg_amcheck`. Because a restored full-machine spore resumes
the snapshotted pgbench processes, the result reports transactions committed
before the first restore-side quiesce separately; that value is not treated as
snapshot drift.

Results and command logs are written beneath
`zig-cache/sporevm-benchmarks/pgbench-snapshot/`. The default scale is 10 so the
spike is practical on both development backends; pass `--scale 100 --disk-size
8gb` for the 1.5 GB working-set shape used in the Tensorlake comparison. The
harness requires at least 2 GiB of free guest disk after scale-100
initialization so PostgreSQL's WAL and checkpoint churn cannot turn capacity
exhaustion into a misleading snapshot failure. Each run also places its sparse
runtime overlay in the task-owned work directory instead of the host's shared
temporary root, keeping host filesystem pressure isolated between benchmark
runs. This remains outside the
scheduled benchmark suite until the workload has established a useful baseline
and an architecture decision needs a durable regression guardrail.

The `disk_metrics` object separates logical parent data referenced by the new
index from what publication actually did. `parent_referenced_bytes` counts
logical nonzero parent references before digest deduplication;
`parent_object_bytes` is the unique parent data considered for publication.
`parent_link_bytes`, `parent_reuse_bytes`, and `parent_copy_bytes` partition
it. Their matching
object counts and microsecond timings show whether save used same-filesystem
hard links, found objects already present, or paid the cross-filesystem verified
copy fallback. `parent_sync_us` records the final directory durability barrier
after batched hard links. Schema 2 additionally partitions every logical chunk
into a sealed/scanned candidate, nonzero parent reuse, clean known-zero reuse,
or a dirty zero recorded without payload work. The parser retains strict
schema-1 support for checked-in historical evidence. The record also reports
dirty versus non-dirty chunks, index encoding/publication, dirty-object writes,
and total disk snapshot time. RAM
and whole-capture timings remain in the backend snapshot metric and the
benchmark's `snapshot_metrics` and `duration_ms`; do not substitute either for
disk snapshot cost. `snapshot_metrics` retains the backend's machine, device,
generation, RAM, disk, manifest, and total snapshot millisecond breakdown.
When dirty-object sealing runs in parallel, its zero-scan, hash, and object-write
timings report the slowest worker's phase rather than summing overlapping worker
intervals, so they remain comparable with the wall-clock disk total.

Use `--work-dir` and `--cache-dir` to make filesystem placement explicit. For
example, placing both beneath the prepared NVMe scratch measures the normal
same-filesystem path. Placing the cache on that scratch and the work directory
on a different filesystem measures portable save-output copy cost. Verify the
mounts with `findmnt -T` before interpreting the result. The disk parser is
bounded to 4 KiB and the backend snapshot parser to 8 KiB. They reject
duplicate, missing, malformed, or internally inconsistent required fields, and
the disk schema also rejects unknown fields. A standalone regression test
covers both:

```console
python3 scripts/benchmark/parse-save-metrics.py --self-test
```

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

The detector compares each current run median against the median of the last
five compatible, non-fail-tier run medians from the same `host_id`. Once a
metric reaches the fail tier, the detector freezes that pre-regression baseline
until the metric recovers, so a sustained regression cannot ratchet its own
baseline upward and turn green. Each archived regression report carries that
state into the next bounded S3 history download. Non-scheduled runs tolerate
empty or missing history so developers can run the same script locally.
Scheduled Buildkite runs fail when no compatible same-host history exists
unless the current run declares an intentional reset with
`SPOREVM_BENCHMARK_RESET` or a
`spore-benchmark-reset:` commit-message line. The failure annotation points at
the likely causes: artifact fetch failure, `host_id` drift, or a fresh pipeline
that needs an intentional bootstrap.

Only headline timing fields are rolling guardrails: `tti_ms`, `elapsed_ms`,
`wall_clock_ms`, `time_to_first_ready_ms`, `fork_ms_per_child`, `pull_ms`,
`resume_exec_ms`, `vsock_connect_ms`, and `exec_response_ms`. Other phase and
guest timers remain in the raw results and site exports for diagnosis, but do
not affect the build unless `benchmarks/expectations.json` gives the matching
metric an absolute ceiling. Counters, success rates, and rootfs digests retain
their guardrails.

The detector also checks durable absolute ceilings from
`benchmarks/expectations.json`. A metric that exceeds its `max` value fails even
without historical confirmation. These ceilings are the long-lived floor for
headline guardrail metrics and should be changed deliberately in PRs, unlike
the rolling baseline that is refreshed from scheduled observations after a
metric recovers.

Thresholds are metric-class based:

- latency metrics such as warm image TTI, warm spore TTI, fork latency,
  `vsock_connect_ms`, and `exec_response_ms`: warn at 30 percent, fail at 60
  percent, and ignore changes smaller than 50ms;
- throughput/import metrics such as synthetic cold import and batch wall times:
  warn at 10 percent, fail at 20 percent, and ignore changes smaller than
  50ms;
- counter metrics such as rootfs objects, chunks, bytes, and block counts: warn
  on any change, fail when an increase reaches 2x or moves from zero to nonzero.
- digest metrics such as `cold_import/synthetic_tar/rootfs_import_index_digest`:
  fail on any change against compatible history;
- success-rate metrics derived from raw benchmark rows before failed rows are
  filtered: fail immediately on any decrease.

Relative timing regressions must reach the fail tier in two consecutive
compatible runs before failing the build. The first fail-tier breach is a
warning. Durable absolute ceilings, digest changes, counter changes, and
success-rate failures are evaluated immediately rather than waiting for a
confirmation run.

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
The main `sporevm` pipeline does not trigger that benchmark suite. It defines
the Linux and macOS named-restore release matrix as opt-in jobs, and omits them
unless `SPOREVM_RUN_NAMED_RESTORE_BENCHMARK=1` is set for the build. Ordinary
Linux and macOS test jobs always run the named-restore parser, cleanup/signal,
path-sanitization, and pinned-release-input self-tests.

The dedicated benchmark pipeline runs macOS and Linux ARM64 benchmark jobs in
parallel on `sporevm-mac` and `sporevm-linux-arm64`. Each platform job uses a
per-platform concurrency group so two benchmark builds do not share the same
runner class at once. It defaults to `nightly` for Buildkite schedules,
`comparison` on `main`, and `ci` otherwise. Override with
`SPOREVM_BENCHMARK_PROFILE=ci` for a short cold/warm run, `nightly` for the
guardrail selection, or `full` when a build should pay for the full benchmark
matrix.

Before the timed suite starts, the CI wrapper logs the host load averages and
CPU count. Set `SPOREVM_BENCHMARK_MAX_LOADAVG_1M` or
`SPOREVM_BENCHMARK_MAX_LOADAVG_1M_PER_CPU` to wait for a trustworthy load
level. `SPOREVM_BENCHMARK_LOAD_WAIT_TIMEOUT_SECONDS` bounds the wait; the
wrapper samples every 15 seconds and fails immediately unless the timeout is
greater than zero.

The general benchmark CI wrapper honors `SPOREVM_BENCHMARK_SCRATCH_ROOT` when
set. Otherwise it uses `/var/tmp/nvme/sporevm-benchmarks` when that prepared
path exists and is writable, falling back to the checkout disk.

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

Before the regression detector runs, the CI wrapper downloads prior
`results.jsonl`, `config.json`, `summary.json`, and `regression-report.json`
objects from the benchmark history S3 bucket into
`zig-cache/sporevm-benchmarks/history`. Set `SPOREVM_BENCHMARK_HISTORY_DIR` to
point at a local history directory, or `SPOREVM_BENCHMARK_HISTORY_BUILDS` to
change the number of prior runs downloaded. Missing history is allowed; the
detector emits `no_history` rows and keeps non-scheduled builds green until
comparable history exists. Scheduled builds require at least one compatible
same-host history run unless the current run carries an intentional reset
marker, so history download failures or host-id drift do not silently disable
the guardrail. Once a benchmark suite has produced a complete result, the
wrapper publishes that observation and its regression report to S3 even when
regression detection fails. Failed observations therefore remain available for
variance analysis and consecutive-run confirmation instead of disappearing
from history.

Regardless of comparison result, the step exports `site/data.json` and
`site/data.js`, uploads benchmark JSON, logs, rootfs metadata, trend data,
`regression-report.md`, and `regression-report.json` as artifacts and S3
objects, and publishes Buildkite annotations summarizing both the latest
benchmark run and regression verdicts. Generated work directories, bundle
chunks, downloaded history, and rootfs chunk stores stay out of S3.
