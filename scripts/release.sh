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

[[ -z "$(git status --porcelain)" ]] || die "working tree must be clean before tagging"

NEXT="$(svu next)"
CURRENT="$(svu current)"
if [[ "${NEXT}" == "${CURRENT}" ]]; then
  die "no version bump detected (current: ${CURRENT}); use conventional commits such as feat: or fix:"
fi

VERSION="${NEXT#v}"
if ! grep -Fq "pub const version = \"${VERSION}\";" src/root.zig; then
  die "src/root.zig version must be ${VERSION} before tagging ${NEXT}"
fi

if git rev-parse --verify --quiet "refs/tags/${NEXT}" >/dev/null; then
  die "tag already exists locally: ${NEXT}"
fi

echo "Releasing ${CURRENT} -> ${NEXT}"
git tag -a "${NEXT}" -m "${NEXT}"
git push origin "${NEXT}"
echo "Tagged and pushed ${NEXT}; Buildkite will publish the GitHub release from the tag build."
