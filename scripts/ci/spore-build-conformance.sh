#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"
: "${BUILDKITE_AGENT_NAME:?BUILDKITE_AGENT_NAME is required}"
: "${BUILDKITE_PARALLEL_JOB:?BUILDKITE_PARALLEL_JOB is required}"
: "${BUILDKITE_PARALLEL_JOB_COUNT:?BUILDKITE_PARALLEL_JOB_COUNT is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

echo "--- :zig: Build ReleaseSafe conformance binary"
release_build_log="zig-cache/spore-build-conformance/${BUILDKITE_JOB_ID}.release-build.log"
mkdir -p "$(dirname "${release_build_log}")"
if zig build --release=safe >"${release_build_log}" 2>&1; then
  echo "ReleaseSafe build complete"
else
  status=$?
  tail -n 200 "${release_build_log}"
  exit "${status}"
fi

conformance_root="zig-cache/spore-build-conformance/${BUILDKITE_JOB_ID}"
mkdir -p "${conformance_root}/logs"
buildx_root="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-buildx.XXXXXX")"
trap 'rm -rf "${buildx_root}"' EXIT
export DOCKER_CONFIG="${buildx_root}/docker"
mkdir -p "${DOCKER_CONFIG}/cli-plugins"

echo "--- :docker: Install the pinned Buildx oracle"
buildx_tool="aqua:docker/buildx@0.33.0"
agent_cache_key="$(printf '%s' "${BUILDKITE_AGENT_NAME}" | sha256sum | cut -c1-16)"
fast_scratch="${SPOREVM_CI_FAST_SCRATCH:-/var/tmp/nvme}"
buildx_mise_root="${fast_scratch}/mise-buildx/${agent_cache_key}"
buildx_install_log="${conformance_root}/logs/mise-buildx-install.log"
mkdir -p "${buildx_mise_root}/data" "${buildx_mise_root}/cache" "${buildx_mise_root}/state"
if env \
  MISE_DATA_DIR="${buildx_mise_root}/data" \
  MISE_CACHE_DIR="${buildx_mise_root}/cache" \
  MISE_STATE_DIR="${buildx_mise_root}/state" \
  mise install "${buildx_tool}" >"${buildx_install_log}" 2>&1; then
  :
else
  status=$?
  tail -n 100 "${buildx_install_log}"
  exit "${status}"
fi
buildx_install_dir="$(env \
  MISE_DATA_DIR="${buildx_mise_root}/data" \
  MISE_CACHE_DIR="${buildx_mise_root}/cache" \
  MISE_STATE_DIR="${buildx_mise_root}/state" \
  mise where "${buildx_tool}")"
install -m 0755 \
  "${buildx_install_dir}/docker-cli-plugin-docker-buildx" \
  "${DOCKER_CONFIG}/cli-plugins/docker-buildx"
docker buildx version | grep -F 'github.com/docker/buildx v0.33.0 '

echo "+++ :test_tube: Run conformance shard $((BUILDKITE_PARALLEL_JOB + 1))/${BUILDKITE_PARALLEL_JOB_COUNT}"
scripts/spore-build-conformance.py \
  --spore-bin zig-out/bin/spore \
  --work-dir "${conformance_root}" \
  --builder-cache-scope "${BUILDKITE_AGENT_NAME}" \
  --buildkitd-config scripts/ci/buildkitd.toml \
  --shard-index "${BUILDKITE_PARALLEL_JOB}" \
  --shard-count "${BUILDKITE_PARALLEL_JOB_COUNT}"
