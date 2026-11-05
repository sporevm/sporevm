# SporeVM Benchmark Suite

Run the suite by hand on the host you want to measure:

```console
mise run benchmark
mise run benchmark --profile full
```

The task builds with the shipped `--release=safe` settings, then runs
`scripts/benchmark/suite.py --no-build` with any extra arguments. Debug builds
are much slower and their numbers are not comparable. Profiles are `smoke`,
`ci` (the default), `comparison`, `nightly`, and `full` (100-way runs); see
`PROFILES` in the script for what each selects. `--benchmarks`, `--modes`, and
`--iterations` narrow a run.

By default the suite times `/usr/local/bin/node -v` in
`docker.io/library/node:22-alpine` with fixed 512 MiB memory. It resolves the
image tag to a digest and runs an untimed prewarm before the timed loops, so
registry lookups and rootfs materialization are not counted; pass
`--no-prewarm-rootfs` to measure the cold image path.

Each run writes `config.json`, raw `results.jsonl`, `summary.json`, and logs
under `zig-cache/sporevm-benchmarks/<run-id>/`, and copies the summary to
`zig-cache/sporevm-benchmarks/latest-summary.json`. Use `--scratch-dir PATH`
to keep large work directories and caches on a faster disk. Each `config.json`
also records `benchmarks/expectations.json`, the rough ceilings expected for
key metrics; nothing enforces them.

## Comparing Two Runs

Compare summaries from the same host and profile:

```console
scripts/benchmark/compare.py baseline-summary.json candidate-summary.json
```

It prints median, p95, and p99 TTI deltas per benchmark and mode, and exits
non-zero when median regresses by more than 20 percent, p95 by more than 30
percent, or p99 by more than 40 percent (each by at least 50 ms), when success
rate drops by more than 2 percentage points, or when the candidate lacks a
baseline result. Flags change each threshold; `--only benchmark/mode,...`
limits the comparison and `--allow-missing` tolerates missing results.
