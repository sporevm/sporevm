#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"
: "${BUILDKITE_PARALLEL_JOB:?BUILDKITE_PARALLEL_JOB is required}"
: "${BUILDKITE_PARALLEL_JOB_COUNT:?BUILDKITE_PARALLEL_JOB_COUNT is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

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
buildx_root="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-buildx.XXXXXX")"
trap 'rm -rf "${buildx_root}"' EXIT
export DOCKER_CONFIG="${buildx_root}/docker"
buildx_asset="${buildx_root}/buildx-v0.33.0.linux-arm64"
mkdir -p "${DOCKER_CONFIG}/cli-plugins"
curl --fail --location --silent --show-error --retry 3 \
  --proto '=https' --proto-redir '=https' \
  https://github.com/docker/buildx/releases/download/v0.33.0/buildx-v0.33.0.linux-arm64 \
  --output "${buildx_asset}"
printf '%s  %s\n' \
  204dc28447d3bb48f42ed1ce5747e0885cd57e306506a39029311becdb1ef786 \
  "${buildx_asset}" | sha256sum --check --strict
install -m 0755 \
  "${buildx_asset}" \
  "${DOCKER_CONFIG}/cli-plugins/docker-buildx"
docker buildx version | grep -F 'github.com/docker/buildx v0.33.0 '

scripts/spore-build-conformance.py \
  --spore-bin zig-out/bin/spore \
  --work-dir "${conformance_root}" \
  --shard-index "${BUILDKITE_PARALLEL_JOB}" \
  --shard-count "${BUILDKITE_PARALLEL_JOB_COUNT}"
