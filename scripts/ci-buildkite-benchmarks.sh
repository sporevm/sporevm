#!/usr/bin/env bash
set -euo pipefail

upload_benchmark_artifacts() {
  buildkite-agent artifact upload "zig-cache/sporevm-benchmarks/latest-summary.json" || true
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
benchmark_rootfs_cache_dir="${SPOREVM_BENCHMARK_ROOTFS_CACHE_DIR:-${SPOREVM_ROOTFS_CACHE_DIR:-}}"
benchmark_profile="${SPOREVM_BENCHMARK_PROFILE:-}"
benchmark_image="${SPOREVM_BENCHMARK_IMAGE:-}"
benchmark_command="${SPOREVM_BENCHMARK_COMMAND:-}"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

trap finish_benchmark_step EXIT

mise install
mise run build
prepare_benchmark_scratch
if [[ -z "${benchmark_rootfs_cache_dir}" ]]; then
  benchmark_rootfs_cache_dir="$(default_rootfs_cache_dir)"
fi
export SPOREVM_ROOTFS_CACHE_DIR="${benchmark_rootfs_cache_dir}"
mkdir -p "${benchmark_rootfs_cache_dir}"
if [[ "$(uname -s)" == "Linux" ]]; then
  scripts/smoke-run-auto-memory.sh
  scripts/smoke-lifecycle-auto-memory.sh
fi
if [[ -z "${benchmark_profile}" ]]; then
  if [[ "${BUILDKITE_BRANCH:-}" == "main" ]]; then
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
scripts/benchmark-sporevm-suite.py "${benchmark_args[@]}"
scripts/export-sporevm-benchmark-data.py zig-cache/sporevm-benchmarks/latest-summary.json
if [[ -n "${SPOREVM_BENCHMARK_BASELINE:-}" ]]; then
  scripts/compare-sporevm-benchmarks.py "${SPOREVM_BENCHMARK_BASELINE}" zig-cache/sporevm-benchmarks/latest-summary.json
fi
