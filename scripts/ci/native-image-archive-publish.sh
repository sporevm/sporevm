#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

output="zig-cache/native-image-distribution"
archive="${output}/ci-final-image.tar.gz"
receipt="${output}/receipt.env"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-image-publish.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${output}"

export SPOREVM_ROOTFS_CACHE_DIR="${scratch}/rootfs-cache"
export SPOREVM_RUNTIME_DIR="${scratch}/runtime"

mise run build:release
zig-out/bin/spore build \
  --platform linux/arm64 \
  --tag local/ci-final-image:producer \
  test/image-archive/ci-final-image

pack_output="$(zig-out/bin/spore image pack \
  local/ci-final-image:producer \
  --platform linux/arm64 \
  --out "${archive}")"
printf '%s\n' "${pack_output}"

archive_digest="$(awk '$1 == "archive_digest:" { print $2 }' <<<"${pack_output}")"
image_digest="$(awk '$1 == "image_digest:" { print $2 }' <<<"${pack_output}")"
if [[ ! "${archive_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
   [[ ! "${image_digest}" =~ ^blake3:[0-9a-f]{64}$ ]]; then
  echo "native image pack did not return immutable identities" >&2
  exit 1
fi

printf 'ARCHIVE_DIGEST=%s\nIMAGE_DIGEST=%s\nPLATFORM=%s\n' \
  "${archive_digest}" "${image_digest}" "linux/arm64" >"${receipt}"
echo "published native image archive ${archive_digest} for ${image_digest}"
