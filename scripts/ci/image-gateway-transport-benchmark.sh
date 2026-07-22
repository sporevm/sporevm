#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
case "${platform}" in
  linux/arm64|linux/amd64) ;;
  *) echo "usage: scripts/ci/image-gateway-transport-benchmark.sh linux/arm64|linux/amd64" >&2; exit 2 ;;
esac

[[ -n "${BUILDKITE_BUILD_NUMBER:-}" && -n "${BUILDKITE_COMMIT:-}" ]] || {
  echo "image gateway S3 benchmark must run in Buildkite" >&2
  exit 2
}

arch="${platform#linux/}"
output="zig-cache/image-gateway-transport/${arch}"
backend="s3://sporevm-benchmarks-data/builds/${BUILDKITE_BUILD_NUMBER}/${BUILDKITE_COMMIT}/image-gateway/${arch}/alpine"
target="docker.io/library/alpine@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40"
overlap="docker.io/library/alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"

mkdir -p "${output}"
mise run build
scripts/benchmark/image-gateway-transport.py prepare \
  --source "${overlap}" \
  --platform "${platform}" \
  --spore-bin zig-out/bin/spore \
  --output "${output}/alpine-3.22" \
  --iterations 5
scripts/benchmark/image-gateway-transport.py prepare \
  --source "${target}" \
  --platform "${platform}" \
  --spore-bin zig-out/bin/spore \
  --output "${output}/alpine-3.23" \
  --iterations 5
scripts/benchmark/image-gateway-transport.py run \
  --fixture "${output}/alpine-3.23/fixture" \
  --overlap-fixture "${output}/alpine-3.22/fixture" \
  --output "${output}/s3" \
  --iterations 5 \
  --s3-uri "${backend}" \
  --s3-region ap-southeast-2

echo "image gateway transport benchmark passed: ${platform} ${output}/s3/summary.json"
