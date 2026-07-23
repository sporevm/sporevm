#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

require_command git
require_command svu

source_version() {
  sed -nE 's/^pub const value = "([^"]+)";$/\1/p' src/version.zig
}

require_source_version() {
  local version="$1"
  local source

  source="$(source_version)"
  [[ "${source}" == "${version}" ]] \
    || die "src/version.zig version must be ${version} before tagging v${version}"
  grep -Fq "Version: ${version}" zig-out/lib/pkgconfig/libspore.pc \
    || die "zig-out/lib/pkgconfig/libspore.pc must be ${version}; run mise run check"
  [[ -x zig-out/bin/spore ]] \
    || die "zig-out/bin/spore is missing; run mise run check"
  if ! zig-out/bin/spore --version | grep -Fq "spore ${version} "; then
    die "zig-out/bin/spore --version must report ${version}; run mise run check"
  fi
}

[[ -z "$(git status --porcelain)" ]] || die "working tree must be clean before tagging"

CURRENT="$(svu current)"
NEXT="${SPOREVM_RELEASE_VERSION:-}"
if [[ -z "${NEXT}" ]]; then
  NEXT="$(svu next)"
fi
[[ "${NEXT}" == v* ]] || die "SPOREVM_RELEASE_VERSION must include the v prefix, got: ${NEXT}"
if [[ "${NEXT}" == "${CURRENT}" ]]; then
  die "no version bump detected (current: ${CURRENT}); use conventional commits such as feat: or fix:"
fi

VERSION="${NEXT#v}"
require_source_version "${VERSION}"

if git rev-parse --verify --quiet "refs/tags/${NEXT}" >/dev/null; then
  die "tag already exists locally: ${NEXT}"
fi

echo "Releasing ${CURRENT} -> ${NEXT}"
git tag -a "${NEXT}" -m "${NEXT}"
git push origin "${NEXT}"
echo "Tagged and pushed ${NEXT}; Buildkite will publish the GitHub release from the tag build."
