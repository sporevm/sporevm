#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[build-release-assets] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: scripts/release/build-assets.sh [--target linux-arm64|darwin-arm64|all] [--output DIR]

Build SporeVM release archives into DIR, defaulting to dist/.
With no --target, both Linux ARM64 and macOS ARM64 archives are built.
USAGE
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

hash_files() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    die "missing required command: shasum or sha256sum"
  fi
}

verify_checksum_file() {
  local checksum_file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "${checksum_file}"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${checksum_file}"
  else
    die "missing required command: shasum or sha256sum"
  fi
}

resolve_macos_sdkroot() {
  if [[ -z "${SDKROOT:-}" ]]; then
    require_command xcrun
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export SDKROOT
  fi

  [[ -d "${SDKROOT}/System/Library/Frameworks" ]] \
    || die "macOS SDK framework path is missing under SDKROOT=${SDKROOT}"
}

build_target() {
  local target_key="$1"
  local zig_target asset_dir archive_name lib_asset_dir lib_archive_name prefix staging lib_staging binary
  local -a shared_libs

  # ponytail: lib archives are arm64-only today; omit arch so old mise picks the CLI archive.
  case "${target_key}" in
    linux-arm64)
      zig_target="aarch64-linux-musl"
      asset_dir="spore_Linux_arm64"
      archive_name="${asset_dir}.tar.gz"
      lib_asset_dir="libspore_Linux"
      lib_archive_name="${lib_asset_dir}.tar.gz"
      ;;
    darwin-arm64)
      zig_target="aarch64-macos.13.0"
      asset_dir="spore_Darwin_arm64"
      archive_name="${asset_dir}.tar.gz"
      lib_asset_dir="libspore_Darwin"
      lib_archive_name="${lib_asset_dir}.tar.gz"
      resolve_macos_sdkroot
      require_command codesign
      ;;
    *)
      die "unsupported target: ${target_key}"
      ;;
  esac

  prefix="${WORK_DIR}/${target_key}/prefix"
  staging="${WORK_DIR}/${asset_dir}"
  lib_staging="${WORK_DIR}/${lib_asset_dir}"
  binary="${prefix}/bin/spore"

  echo "--- :zig: Build ${target_key}"
  zig build -Dtarget="${zig_target}" --release=safe --prefix "${prefix}"

  [[ -x "${binary}" ]] || die "missing built binary: ${binary}"
  [[ -f "${prefix}/include/spore.h" ]] || die "missing built header: ${prefix}/include/spore.h"
  [[ -f "${prefix}/lib/libspore.a" ]] || die "missing built static library: ${prefix}/lib/libspore.a"
  [[ -f "${prefix}/lib/pkgconfig/libspore.pc" ]] || die "missing pkg-config file: ${prefix}/lib/pkgconfig/libspore.pc"
  if [[ "${target_key}" == "darwin-arm64" ]]; then
    shared_libs=("${prefix}"/lib/libspore*.dylib)
  else
    shared_libs=("${prefix}"/lib/libspore.so*)
  fi
  [[ -e "${shared_libs[0]}" ]] || die "missing built shared libspore library"

  mkdir -p "${staging}/bin"
  install -m 0755 "${binary}" "${staging}/bin/spore"
  install -m 0644 "${REPO_ROOT}/LICENSE" "${staging}/LICENSE"
  install -m 0644 "${REPO_ROOT}/README.md" "${staging}/README.md"

  file "${staging}/bin/spore"
  if [[ "${target_key}" == "darwin-arm64" ]]; then
    codesign -dv --verbose=2 "${staging}/bin/spore" >/dev/null
    codesign -dv --verbose=2 "${shared_libs[0]}" >/dev/null
  fi

  echo "--- :package: Archive ${archive_name}"
  rm -f "${OUTPUT_DIR}/${archive_name}"
  (
    cd "${WORK_DIR}"
    tar -czf "${OUTPUT_DIR}/${archive_name}" "${asset_dir}"
  )
  ARCHIVE_NAMES+=("${archive_name}")

  mkdir -p "${lib_staging}/docs"
  install -m 0644 "${REPO_ROOT}/LICENSE" "${lib_staging}/LICENSE"
  install -m 0644 "${REPO_ROOT}/README.md" "${lib_staging}/README.md"
  install -m 0644 "${REPO_ROOT}/docs/libspore.md" "${lib_staging}/docs/libspore.md"
  (
    cd "${prefix}"
    tar -cf - include/spore.h lib/libspore* lib/pkgconfig/libspore.pc
  ) | (
    cd "${lib_staging}"
    tar -xf -
  )

  echo "--- :package: Archive ${lib_archive_name}"
  rm -f "${OUTPUT_DIR}/${lib_archive_name}"
  (
    cd "${WORK_DIR}"
    tar -czf "${OUTPUT_DIR}/${lib_archive_name}" "${lib_asset_dir}"
  )
  ARCHIVE_NAMES+=("${lib_archive_name}")
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/dist"
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      shift
      [[ $# -gt 0 ]] || die "--target requires a value"
      TARGETS+=("$1")
      ;;
    --output)
      shift
      [[ $# -gt 0 ]] || die "--output requires a value"
      OUTPUT_DIR="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(linux-arm64 darwin-arm64)
fi

EXPANDED_TARGETS=()
for target in "${TARGETS[@]}"; do
  case "${target}" in
    all)
      EXPANDED_TARGETS+=(linux-arm64 darwin-arm64)
      ;;
    linux-arm64|darwin-arm64)
      EXPANDED_TARGETS+=("${target}")
      ;;
    *)
      die "unsupported target: ${target}"
      ;;
  esac
done

require_command file
require_command install
require_command tar
require_command zig

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
rm -f \
  "${OUTPUT_DIR}/libspore_Darwin.tar.gz" \
  "${OUTPUT_DIR}/libspore_Darwin_arm64.tar.gz" \
  "${OUTPUT_DIR}/libspore_Linux.tar.gz" \
  "${OUTPUT_DIR}/libspore_Linux_arm64.tar.gz" \
  "${OUTPUT_DIR}/spore_Darwin_arm64.tar.gz" \
  "${OUTPUT_DIR}/spore_Linux_arm64.tar.gz" \
  "${OUTPUT_DIR}/checksums.txt"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-release-assets.XXXXXX")"
ARCHIVE_NAMES=()

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

cd "${REPO_ROOT}"

for target in "${EXPANDED_TARGETS[@]}"; do
  build_target "${target}"
done

for archive_name in "${ARCHIVE_NAMES[@]}"; do
  [[ -f "${OUTPUT_DIR}/${archive_name}" ]] || die "missing release archive: ${archive_name}"
  case "${archive_name}" in
    libspore_*_arm64.tar.gz)
      die "libspore release archives must omit arch to keep old mise on CLI assets: ${archive_name}"
      ;;
  esac
done

echo "--- :fingerprint: Write checksums"
(
  cd "${OUTPUT_DIR}"
  hash_files "${ARCHIVE_NAMES[@]}" >checksums.txt
  verify_checksum_file checksums.txt
)

printf '[build-release-assets] wrote release assets to %s\n' "${OUTPUT_DIR}" >&2
