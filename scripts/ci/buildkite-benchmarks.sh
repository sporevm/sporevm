#!/usr/bin/env bash
set -euo pipefail

upload_benchmark_artifacts() {
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/latest-summary.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/regression-report.md" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/regression-report.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/site/*" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/config.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/results.jsonl" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/summary.json" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/logs/*" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/logs/**/*" || true
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/*/rootfs-cache/*.json" || true
}

annotate_benchmark_results() {
  local status="$1"
  local summary="zig-cache/sporevm-benchmarks/latest-summary.json"
  [[ -f "${summary}" ]] || return 0

  local annotation="zig-cache/sporevm-benchmarks/buildkite-annotation.md"
  scripts/benchmark/annotate.py "${summary}" >"${annotation}" || return 0

  local style="success"
  if [[ "${status}" != "0" ]]; then
    style="warning"
  fi
  buildkite-agent annotate --style "${style}" --context "sporevm-benchmarks" --priority 7 <"${annotation}" || true
  buildkite-agent artifact upload "${annotation}" || true
}

annotate_regression_results() {
  local status="$1"
  local report="zig-cache/sporevm-benchmarks/regression-report.md"
  local report_json="zig-cache/sporevm-benchmarks/regression-report.json"
  [[ -f "${report}" ]] || return 0

  local style="info"
  if [[ "${status}" != "0" ]]; then
    style="error"
  elif [[ -f "${report_json}" ]]; then
    style="$(python3 - "${report_json}" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("info")
else:
    print(data.get("summary", {}).get("style", "info"))
PY
)"
  fi
  buildkite-agent annotate --style "${style}" --context "sporevm-benchmark-regressions" --priority 8 <"${report}" || true
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
benchmark_rootfs_cache_dir="${SPOREVM_BENCHMARK_ROOTFS_CACHE_DIR:-${SPOREVM_ROOTFS_CACHE_DIR:-}}"
benchmark_profile="${SPOREVM_BENCHMARK_PROFILE:-}"
benchmark_image="${SPOREVM_BENCHMARK_IMAGE:-}"
benchmark_command="${SPOREVM_BENCHMARK_COMMAND:-}"
benchmark_history_dir="${SPOREVM_BENCHMARK_HISTORY_DIR:-}"

default_rootfs_cache_dir() {
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s\n' "${XDG_CACHE_HOME%/}/sporevm/rootfs"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "${HOME%/}/Library/Caches/sporevm/rootfs"
      ;;
    *)
      printf '%s\n' "${HOME%/}/.cache/sporevm/rootfs"
      ;;
  esac
}

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

wait_for_quiet_benchmark_host() {
  python3 - <<'PY'
import math
import os
import sys
import time

def parse_number(name, raw):
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        print(f"error: invalid {name}={raw!r}", file=sys.stderr)
        sys.exit(1)
    if not math.isfinite(value) or value < 0:
        print(f"error: {name} must be non-negative", file=sys.stderr)
        sys.exit(1)
    return value

limit = parse_number(
    "SPOREVM_BENCHMARK_MAX_LOADAVG_1M",
    os.environ.get("SPOREVM_BENCHMARK_MAX_LOADAVG_1M", ""),
)
per_cpu_limit = parse_number(
    "SPOREVM_BENCHMARK_MAX_LOADAVG_1M_PER_CPU",
    os.environ.get("SPOREVM_BENCHMARK_MAX_LOADAVG_1M_PER_CPU", ""),
)
timeout = parse_number(
    "SPOREVM_BENCHMARK_LOAD_WAIT_TIMEOUT_SECONDS",
    os.environ.get("SPOREVM_BENCHMARK_LOAD_WAIT_TIMEOUT_SECONDS", ""),
) or 0

started = time.monotonic()
while True:
    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        if limit is not None or per_cpu_limit is not None:
            print("error: pre-benchmark loadavg unavailable", file=sys.stderr)
            sys.exit(1)
        print("pre-benchmark loadavg: unavailable", file=sys.stderr)
        sys.exit(0)

    cpus = os.cpu_count() or 1
    load1_per_cpu = load1 / cpus
    print(
        f"pre-benchmark loadavg: 1m={load1:.2f} 5m={load5:.2f} 15m={load15:.2f} "
        f"cpus={cpus} load1_per_cpu={load1_per_cpu:.3f}",
        file=sys.stderr,
    )
    if limit is None and per_cpu_limit is None:
        sys.exit(0)

    quiet = (limit is None or load1 <= limit) and (
        per_cpu_limit is None or load1_per_cpu <= per_cpu_limit
    )
    if quiet:
        sys.exit(0)

    elapsed = time.monotonic() - started
    if elapsed >= timeout:
        print(
            f"error: benchmark host did not become quiet within {timeout:.0f}s",
            file=sys.stderr,
        )
        sys.exit(1)
    time.sleep(min(15, timeout - elapsed))
PY
}

download_benchmark_history() {
  if [[ -n "${benchmark_history_dir}" ]]; then
    printf '%s\n' "${benchmark_history_dir}"
    return 0
  fi
  [[ -n "${BUILDKITE_BUILD_NUMBER:-}" ]] || return 0

  local limit="${SPOREVM_BENCHMARK_HISTORY_BUILDS:-20}"
  local dest="zig-cache/sporevm-benchmarks/history"
  mkdir -p "${dest}"

  local platform
  case "$(uname -s)" in
    Darwin) platform="macos" ;;
    Linux) platform="linux-arm64" ;;
    *) platform="unknown" ;;
  esac
  scripts/benchmark/download-history.sh "${dest}" "${limit}" "${BUILDKITE_BRANCH:-main}" "${platform}" || return 0
  printf '%s\n' "${dest}"
}

publish_benchmark_history() {
  [[ "${BUILDKITE_BRANCH:-}" == "main" ]] || return 0
  command -v aws >/dev/null 2>&1 || return 0

  local platform
  case "$(uname -s)" in
    Darwin) platform="macos" ;;
    Linux) platform="linux-arm64" ;;
    *) return 0 ;;
  esac
  local history_uri="${SPOREVM_BENCHMARK_HISTORY_S3_URI:-s3://sporevm-benchmarks/history}"
  aws s3 sync zig-cache/sporevm-benchmarks/ "${history_uri%/}/main/${platform}/" \
    --no-progress \
    --exclude "*" \
    --include "*/config.json" \
    --include "*/results.jsonl" \
    --include "*/summary.json" \
    --exclude "history/*"
}

run_regression_detector() {
  local summary="zig-cache/sporevm-benchmarks/latest-summary.json"
  [[ -f "${summary}" ]] || return 0

  local history
  history="$(download_benchmark_history || true)"
  local args=(
    "${summary}"
    --markdown-out "zig-cache/sporevm-benchmarks/regression-report.md"
    --json-out "zig-cache/sporevm-benchmarks/regression-report.json"
  )
  if [[ -n "${history}" && -d "${history}" ]]; then
    args+=(--history-dir "${history}")
  fi
  if [[ "${BUILDKITE_SOURCE:-}" == "schedule" ]]; then
    args+=(--require-history)
  fi

  local status=0
  set +e
  scripts/benchmark/detect_regressions.py "${args[@]}"
  status="$?"
  set -e
  annotate_regression_results "${status}"
  return "${status}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

trap finish_benchmark_step EXIT

mise install
# Benchmarks must measure the shipped ReleaseSafe build settings; a default
# Debug build understates TTI by roughly 40 percent.
mise run build:release
prepare_benchmark_scratch
if [[ -z "${benchmark_rootfs_cache_dir}" ]]; then
  benchmark_rootfs_cache_dir="$(default_rootfs_cache_dir)"
fi
export SPOREVM_ROOTFS_CACHE_DIR="${benchmark_rootfs_cache_dir}"
mkdir -p "${benchmark_rootfs_cache_dir}"
if [[ "$(uname -s)" == "Linux" ]]; then
  test/smoke/run/auto-memory.sh
  test/smoke/lifecycle/auto-memory.sh
fi
if [[ -z "${benchmark_profile}" ]]; then
  if [[ "${BUILDKITE_SOURCE:-}" == "schedule" ]]; then
    benchmark_profile="nightly"
  elif [[ "${BUILDKITE_BRANCH:-}" == "main" ]]; then
    benchmark_profile="comparison"
  else
    benchmark_profile="ci"
  fi
fi
# Default to the Docker Official node image via the AWS public ECR mirror so
# benchmark builds match the public sandbox TTI shape (node runtime, `node -v`
# first command, per https://www.computesdk.com/benchmarks/sandboxes/) without
# depending on Docker Hub rate limits. The suite resolves the tag once before
# timed loops, and the resolve fallback plus the persistent rootfs cache keep
# builds working through registry blips.
benchmark_image="${benchmark_image:-public.ecr.aws/docker/library/node:22-alpine}"
benchmark_args=(--profile "${benchmark_profile}" --no-build)
if [[ -n "${benchmark_image}" ]]; then
  benchmark_args+=(--image "${benchmark_image}")
fi
if [[ -n "${benchmark_command}" ]]; then
  benchmark_args+=(--command "${benchmark_command}")
fi
if [[ "${SPOREVM_BENCHMARK_ALLOW_IMAGE_RESOLVE_FALLBACK:-}" == "1" ]]; then
  benchmark_args+=(--allow-image-resolve-fallback)
fi
if [[ -n "${benchmark_scratch_dir}" ]]; then
  benchmark_args+=(--scratch-dir "${benchmark_scratch_dir}")
fi
if [[ -n "${benchmark_rootfs_cache_dir}" ]]; then
  benchmark_args+=(--rootfs-cache-dir "${benchmark_rootfs_cache_dir}")
fi
wait_for_quiet_benchmark_host
scripts/benchmark/suite.py "${benchmark_args[@]}"
scripts/benchmark/export-site-data.py zig-cache/sporevm-benchmarks/latest-summary.json
run_regression_detector
publish_benchmark_history
if [[ -n "${SPOREVM_BENCHMARK_BASELINE:-}" ]]; then
  scripts/benchmark/compare.py "${SPOREVM_BENCHMARK_BASELINE}" zig-cache/sporevm-benchmarks/latest-summary.json
fi
