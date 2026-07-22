#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/ci/image-gateway-worker-conformance.sh linux/arm64|linux/amd64" >&2
  exit 2
fi

worker="$1"
case "${worker}" in
  linux/arm64|linux/amd64) ;;
  *)
    echo "unsupported worker: ${worker}" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

worker_arch="${worker#linux/}"
output="zig-cache/image-gateway-worker-conformance/${BUILDKITE_JOB_ID}/${worker_arch}"
if [[ -e "${output}" ]]; then
  echo "conformance output already exists: ${output}" >&2
  exit 1
fi

echo "--- :zig: Build worker conformance binary"
zig build --release=safe

echo "+++ :test_tube: Verify ${worker} converter output"
scripts/image-gateway-worker-conformance.py produce \
  --spore-bin zig-out/bin/spore \
  --worker "${worker}" \
  --output "${output}" \
  --expected test/image-gateway/worker-conformance
