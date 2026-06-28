#!/usr/bin/env bash
set -euo pipefail

upload_benchmark_artifacts() {
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/latest-summary.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/site/*" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/config.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/results.jsonl" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/summary.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/logs/*" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/rootfs-cache/*.json" || true
}

annotate_benchmark_results() {
  local status="$1"
  local summary="zig-cache/sporevm-benchmarks/latest-summary.json"
  [[ -f "${summary}" ]] || return 0

  local annotation="zig-cache/sporevm-benchmarks/buildkite-annotation.md"
  scripts/annotate-sporevm-benchmarks.py "${summary}" >"${annotation}" || return 0

  local style="success"
  if [[ "${status}" != "0" ]]; then
    style="warning"
  fi
  buildkite-agent annotate --style "${style}" --context "sporevm-benchmarks" --priority 7 <"${annotation}" || true
  buildkite-agent artifact upload "${annotation}" || true
}

finish_benchmark_step() {
  local status="$?"
  trap - EXIT
  upload_benchmark_artifacts
  annotate_benchmark_results "${status}"
  cleanup_benchmark_scratch
  exit "${status}"
}

choose_prepared_scratch_root() {
  local candidate="/var/tmp/nvme/sporevm-benchmarks"
  [[ -d "${candidate}" && -w "${candidate}" ]] || return 1
  printf '%s\n' "${candidate}"
}

choose_benchmark_scratch_root() {
  if [[ -n "${SPOREVM_BENCHMARK_SCRATCH_ROOT:-}" ]]; then
    mkdir -p "${SPOREVM_BENCHMARK_SCRATCH_ROOT}"
    [[ -w "${SPOREVM_BENCHMARK_SCRATCH_ROOT}" ]] || {
      echo "error: SPOREVM_BENCHMARK_SCRATCH_ROOT is not writable: ${SPOREVM_BENCHMARK_SCRATCH_ROOT}" >&2
      return 1
    }
    printf '%s\n' "${SPOREVM_BENCHMARK_SCRATCH_ROOT}"
    return 0
  fi

  choose_prepared_scratch_root
}

benchmark_scratch_dir=""

prepare_benchmark_scratch() {
  local root
  if [[ -n "${SPOREVM_BENCHMARK_SCRATCH_ROOT:-}" ]]; then
    root="$(choose_benchmark_scratch_root)"
  else
    root="$(choose_benchmark_scratch_root || true)"
  fi
  [[ -n "${root}" ]] || return 0

  benchmark_scratch_dir="$(mktemp -d "${root%/}/sporevm-benchmark.XXXXXX")"
  mkdir -p "${benchmark_scratch_dir}/tmp"
  export TMPDIR="${benchmark_scratch_dir}/tmp"
  echo "using benchmark scratch: ${benchmark_scratch_dir}" >&2
}

cleanup_benchmark_scratch() {
  [[ -n "${benchmark_scratch_dir}" ]] || return 0
  [[ -z "${SPORE_KEEP_BENCH_SCRATCH:-}" ]] || {
    echo "kept benchmark scratch: ${benchmark_scratch_dir}" >&2
    return 0
  }
  rm -rf "${benchmark_scratch_dir}" || true
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

trap finish_benchmark_step EXIT

mise install
mise run build
prepare_benchmark_scratch
if [[ "$(uname -s)" == "Linux" ]]; then
  scripts/smoke-run-auto-memory.sh
fi
benchmark_args=(--profile "${SPOREVM_BENCHMARK_PROFILE:-comparison}" --no-build)
if [[ -n "${benchmark_scratch_dir}" ]]; then
  benchmark_args+=(--scratch-dir "${benchmark_scratch_dir}")
fi
scripts/benchmark-sporevm-suite.py "${benchmark_args[@]}"
scripts/export-sporevm-benchmark-data.py zig-cache/sporevm-benchmarks/latest-summary.json
if [[ -n "${SPOREVM_BENCHMARK_BASELINE:-}" ]]; then
  scripts/compare-sporevm-benchmarks.py "${SPOREVM_BENCHMARK_BASELINE}" zig-cache/sporevm-benchmarks/latest-summary.json
fi
