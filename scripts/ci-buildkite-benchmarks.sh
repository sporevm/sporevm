#!/usr/bin/env bash
set -euo pipefail

upload_benchmark_artifacts() {
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/latest-summary.json" || true
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
  exit "${status}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

trap finish_benchmark_step EXIT

mise install
mise run build
scripts/benchmark-sporevm-suite.py --profile "${SPOREVM_BENCHMARK_PROFILE:-comparison}" --no-build
if [[ -n "${SPOREVM_BENCHMARK_BASELINE:-}" ]]; then
  scripts/compare-sporevm-benchmarks.py "${SPOREVM_BENCHMARK_BASELINE}" zig-cache/sporevm-benchmarks/latest-summary.json
fi
