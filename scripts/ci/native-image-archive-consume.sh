#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

output="zig-cache/native-image-distribution"
archive="${output}/ci-final-image.tar.gz"
receipt="${output}/receipt.env"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-image-consume.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${output}"

buildkite-agent artifact download "${archive}" . --step native-image-archive-publish-linux-arm64
buildkite-agent artifact download "${receipt}" . --step native-image-archive-publish-linux-arm64
ARCHIVE_DIGEST="$(awk -F= '$1 == "ARCHIVE_DIGEST" { print $2 }' "${receipt}")"
IMAGE_DIGEST="$(awk -F= '$1 == "IMAGE_DIGEST" { print $2 }' "${receipt}")"
PLATFORM="$(awk -F= '$1 == "PLATFORM" { print $2 }' "${receipt}")"
if [[ ! "${ARCHIVE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
   [[ ! "${IMAGE_DIGEST}" =~ ^blake3:[0-9a-f]{64}$ ]] ||
   [[ "${PLATFORM}" != "linux/arm64" ]]; then
  echo "native image artifact receipt is invalid" >&2
  exit 1
fi

export SPOREVM_ROOTFS_CACHE_DIR="${scratch}/rootfs-cache"
export SPOREVM_RUNTIME_DIR="${scratch}/runtime"

mise run build:release
unpack_output="$(zig-out/bin/spore image unpack \
  "${archive}" \
  --archive-digest "${ARCHIVE_DIGEST}" \
  --platform "${PLATFORM}" \
  --ref local/ci-final-image:consumer)"
printf '%s\n' "${unpack_output}"

resolved_image="$(awk '$1 == "image_digest:" { print $2 }' <<<"${unpack_output}")"
if [[ "${resolved_image}" != "${IMAGE_DIGEST}" ]]; then
  echo "unpacked native image identity changed: expected ${IMAGE_DIGEST}, got ${resolved_image}" >&2
  exit 1
fi

run_output="$(zig-out/bin/spore run \
  --image local/ci-final-image:consumer \
  --pull=never)"
if [[ "${run_output}" != *"native-image-archive-ok"* ]]; then
  printf '%s\n' "${run_output}" >&2
  echo "clean worker did not run the unpacked native image" >&2
  exit 1
fi
printf '%s\n' "${run_output}"
echo "clean worker ran immutable native image ${IMAGE_DIGEST}"
