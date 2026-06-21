#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[ci-buildkite-release] error: %s\n' "$*" >&2
  exit 1
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

fetch_optional_secret() {
  local key="$1"
  buildkite-agent secret get "${key}" 2>/dev/null || true
}

normalize_secret_value() {
  printf '%s' "$1" | tr -d '\r'
}

load_github_token() {
  local github_token

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    github_token="$(normalize_secret_value "$(fetch_optional_secret SPOREVM_GITHUB_RELEASE_TOKEN)")"
    [[ -n "${github_token}" ]] || die "GITHUB_TOKEN or Buildkite secret SPOREVM_GITHUB_RELEASE_TOKEN is required"
    export GITHUB_TOKEN="${github_token}"
  fi

  export GH_TOKEN="${GITHUB_TOKEN}"
  export GH_PROMPT_DISABLED=1
}

verify_release_archive() {
  local asset_path="$1"
  local root_dir="$2"
  local entry listing

  listing="$(tar -tzf "${asset_path}")"
  for entry in \
    "${root_dir}/spore" \
    "${root_dir}/LICENSE" \
    "${root_dir}/README.md" \
    "${root_dir}/share/sporevm/minimal-exec-initrd.cpio"; do
    grep -Fxq "${entry}" <<<"${listing}" \
      || die "missing ${entry} in ${asset_path}"
  done
}

download_release_archive() {
  local asset_name="$1"
  local step_key="$2"
  local asset_path="${ASSET_DIR}/${asset_name}"
  local root_dir="${asset_name%.tar.gz}"

  buildkite-agent artifact download "dist/${asset_name}" "${REPO_ROOT}" --step "${step_key}"
  [[ -f "${asset_path}" ]] || die "missing downloaded release asset: ${asset_path}"
  verify_release_archive "${asset_path}" "${root_dir}"
}

download_release_archives() {
  rm -rf "${ASSET_DIR}"
  mkdir -p "${ASSET_DIR}"

  download_release_archive "spore_Darwin_arm64.tar.gz" "release-darwin-arm64"
  download_release_archive "spore_Linux_arm64.tar.gz" "release-linux-arm64"
}

write_checksums() {
  (
    cd "${ASSET_DIR}"
    hash_files "${EXPECTED_ASSETS[@]}" >checksums.txt
    verify_checksum_file checksums.txt
  )
}

create_or_update_release() {
  local notes_path="docs/releases/${BUILDKITE_TAG}.md"

  if gh release view "${BUILDKITE_TAG}" --repo "${GITHUB_REPOSITORY_NAME}" >/dev/null 2>&1; then
    if [[ -f "${notes_path}" ]]; then
      gh release edit "${BUILDKITE_TAG}" \
        --repo "${GITHUB_REPOSITORY_NAME}" \
        --title "SporeVM ${BUILDKITE_TAG}" \
        --notes-file "${notes_path}" \
        --prerelease
    else
      gh release edit "${BUILDKITE_TAG}" \
        --repo "${GITHUB_REPOSITORY_NAME}" \
        --title "SporeVM ${BUILDKITE_TAG}" \
        --prerelease
    fi
    return
  fi

  if [[ -f "${notes_path}" ]]; then
    gh release create "${BUILDKITE_TAG}" \
      --repo "${GITHUB_REPOSITORY_NAME}" \
      --verify-tag \
      --title "SporeVM ${BUILDKITE_TAG}" \
      --notes-file "${notes_path}" \
      --prerelease \
      --latest=false
  else
    gh release create "${BUILDKITE_TAG}" \
      --repo "${GITHUB_REPOSITORY_NAME}" \
      --verify-tag \
      --title "SporeVM ${BUILDKITE_TAG}" \
      --generate-notes \
      --prerelease \
      --latest=false
  fi
}

upload_release_assets() {
  gh release upload "${BUILDKITE_TAG}" \
    "${ASSET_DIR}/spore_Darwin_arm64.tar.gz" \
    "${ASSET_DIR}/spore_Linux_arm64.tar.gz" \
    "${ASSET_DIR}/checksums.txt" \
    --repo "${GITHUB_REPOSITORY_NAME}" \
    --clobber
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSET_DIR="${REPO_ROOT}/dist"
GITHUB_REPOSITORY_NAME="${SPOREVM_GITHUB_REPOSITORY:-buildkite/sporevm}"
EXPECTED_ASSETS=(
  spore_Darwin_arm64.tar.gz
  spore_Linux_arm64.tar.gz
)

require_command buildkite-agent
require_command gh
require_command git
require_command grep
require_command tar

[[ -n "${BUILDKITE_TAG:-}" ]] || die "BUILDKITE_TAG is required for release publishing"
load_github_token

cd "${REPO_ROOT}"
git fetch --tags origin

echo "--- :package: Download release archives"
download_release_archives

echo "--- :fingerprint: Write checksums"
write_checksums

echo "--- :rocket: Publish GitHub release"
create_or_update_release
upload_release_assets
