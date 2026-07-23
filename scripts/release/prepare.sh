#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[prepare-release] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: scripts/release/prepare.sh vX.Y.Z

Update source and package versions for the next SporeVM release.
USAGE
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 1
}

NEXT="$1"
[[ "${NEXT}" == v* ]] || die "version must include the v prefix, got: ${NEXT}"
VERSION="${NEXT#v}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be vMAJOR.MINOR.PATCH, got: ${NEXT}"

perl -0pi -e "s/pub const value = \"[^\"]+\";/pub const value = \"${VERSION}\";/" src/version.zig

grep -Fq "pub const value = \"${VERSION}\";" src/version.zig \
  || die "failed to update src/version.zig"

printf '[prepare-release] prepared %s\n' "${NEXT}"
