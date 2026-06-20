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

fetch_optional_secret() {
  local key="$1"
  buildkite-agent secret get "${key}" 2>/dev/null || true
}

normalize_secret_value() {
  printf '%s' "$1" | tr -d '\r'
}

load_github_token() {
  local github_token

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return
  fi

  github_token="$(normalize_secret_value "$(fetch_optional_secret SPOREVM_GITHUB_RELEASE_TOKEN)")"
  [[ -n "${github_token}" ]] || die "GITHUB_TOKEN or Buildkite secret SPOREVM_GITHUB_RELEASE_TOKEN is required"
  export GITHUB_TOKEN="${github_token}"
}

require_macos_arm64() {
  [[ "$(uname -s)" == "Darwin" ]] || die "release publishing must run on macOS so the HVF binary is signed"
  [[ "$(uname -m)" == "arm64" ]] || die "release publishing must run on Apple Silicon so zig build applies HVF signing"
}

resolve_macos_sdkroot() {
  if [[ -n "${SDKROOT:-}" ]]; then
    return
  fi

  require_command xcrun
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  [[ -d "${SDKROOT}/System/Library/Frameworks" ]] || die "macOS SDK framework path is missing under SDKROOT=${SDKROOT}"
  export SDKROOT
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_command buildkite-agent
require_command git
require_command goreleaser
require_command uname

[[ -n "${BUILDKITE_TAG:-}" ]] || die "BUILDKITE_TAG is required for release publishing"
require_macos_arm64
resolve_macos_sdkroot
load_github_token

cd "${REPO_ROOT}"
git fetch --tags origin

echo "--- :package: Prepare release archive extras"
scripts/prepare-release-extra.sh

release_notes="docs/releases/${BUILDKITE_TAG}.md"
release_args=(release --clean)
if [[ -f "${release_notes}" ]]; then
  release_args+=(--release-notes "${release_notes}")
fi

echo "--- :rocket: Publish GitHub release"
goreleaser "${release_args[@]}"
