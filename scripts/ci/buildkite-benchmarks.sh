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

check_benchmark_host_load() {
  python3 - <<'PY'
import os
import sys

limit_raw = os.environ.get("SPOREVM_BENCHMARK_MAX_LOADAVG_1M", "")
try:
    load1, load5, load15 = os.getloadavg()
except OSError:
    if limit_raw:
        print("error: pre-benchmark loadavg unavailable", file=sys.stderr)
        sys.exit(1)
    print("pre-benchmark loadavg: unavailable", file=sys.stderr)
    sys.exit(0)

cpus = os.cpu_count() or 1
print(
    f"pre-benchmark loadavg: 1m={load1:.2f} 5m={load5:.2f} 15m={load15:.2f} "
    f"cpus={cpus} load1_per_cpu={load1 / cpus:.3f}",
    file=sys.stderr,
)
if not limit_raw:
    sys.exit(0)
try:
    limit = float(limit_raw)
except ValueError:
    print(f"error: invalid SPOREVM_BENCHMARK_MAX_LOADAVG_1M={limit_raw!r}", file=sys.stderr)
    sys.exit(1)
if load1 > limit:
    print(f"error: pre-benchmark 1m loadavg {load1:.2f} exceeds {limit:.2f}", file=sys.stderr)
    sys.exit(1)
PY
}

download_benchmark_history() {
  if [[ -n "${benchmark_history_dir}" ]]; then
    printf '%s\n' "${benchmark_history_dir}"
    return 0
  fi
  [[ -n "${BUILDKITE_BUILD_NUMBER:-}" ]] || return 0
  command -v buildkite-agent >/dev/null 2>&1 || return 0

  local limit="${SPOREVM_BENCHMARK_HISTORY_BUILDS:-20}"
  local dest="zig-cache/sporevm-benchmarks/history"
  mkdir -p "${dest}"

  download_history_build() {
    local build_ref="$1"
    local label
    label="$(printf '%s' "${build_ref}" | tr -c 'A-Za-z0-9_.-' '_')"
    local build_dest="${dest}/build-${label}"
    mkdir -p "${build_dest}"
    buildkite-agent artifact download "zig-cache/sporevm-benchmarks/*/results.jsonl" "${build_dest}" --build "${build_ref}" >/dev/null 2>&1 || true
    buildkite-agent artifact download "zig-cache/sporevm-benchmarks/*/config.json" "${build_dest}" --build "${build_ref}" >/dev/null 2>&1 || true
    buildkite-agent artifact download "zig-cache/sporevm-benchmarks/*/summary.json" "${build_dest}" --build "${build_ref}" >/dev/null 2>&1 || true
  }

  local downloaded=0
  if [[ -n "${BUILDKITE_API_TOKEN:-}" && -n "${BUILDKITE_ORGANIZATION_SLUG:-}" && -n "${BUILDKITE_PIPELINE_SLUG:-}" ]]; then
    while IFS= read -r build_id; do
      [[ -n "${build_id}" ]] || continue
      download_history_build "${build_id}"
      downloaded=1
    done < <(python3 - "${limit}" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

limit = int(sys.argv[1])
token = os.environ.get("BUILDKITE_API_TOKEN")
org = os.environ.get("BUILDKITE_ORGANIZATION_SLUG")
pipeline = os.environ.get("BUILDKITE_PIPELINE_SLUG")
current_raw = os.environ.get("BUILDKITE_BUILD_NUMBER", "0")
branch = os.environ.get("BUILDKITE_BRANCH", "")
try:
    current = int(current_raw)
except ValueError:
    current = 0
if not token or not org or not pipeline or current <= 0:
    raise SystemExit(0)

query = {"per_page": str(max(limit * 2, limit))}
if branch:
    query["branch"] = branch
url = (
    "https://api.buildkite.com/v2/organizations/"
    + urllib.parse.quote(org)
    + "/pipelines/"
    + urllib.parse.quote(pipeline)
    + "/builds?"
    + urllib.parse.urlencode(query)
)
request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        builds = json.load(response)
except Exception:
    raise SystemExit(0)

emitted = 0
for build in builds:
    number = build.get("number")
    build_id = build.get("id")
    if not isinstance(number, int) or not isinstance(build_id, str):
        continue
    if number >= current:
        continue
    print(build_id)
    emitted += 1
    if emitted >= limit:
        break
PY
)
  fi

  if [[ "${downloaded}" == "0" ]]; then
    local current="${BUILDKITE_BUILD_NUMBER}"
    local offset build
    for offset in $(seq 1 "${limit}"); do
      build=$((current - offset))
      [[ "${build}" -gt 0 ]] || break
      download_history_build "${build}"
    done
  fi
  printf '%s\n' "${dest}"
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
check_benchmark_host_load
scripts/benchmark/suite.py "${benchmark_args[@]}"
scripts/benchmark/export-site-data.py zig-cache/sporevm-benchmarks/latest-summary.json
run_regression_detector
if [[ -n "${SPOREVM_BENCHMARK_BASELINE:-}" ]]; then
  scripts/benchmark/compare.py "${SPOREVM_BENCHMARK_BASELINE}" zig-cache/sporevm-benchmarks/latest-summary.json
fi
