#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[prepare-release] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: scripts/prepare-release.sh vX.Y.Z

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

IFS=. read -r MAJOR MINOR PATCH <<<"${VERSION}"

perl -0pi -e "s/pub const value = \"[^\"]+\";/pub const value = \"${VERSION}\";/" src/version.zig
perl -0pi -e "s/const libspore_version = std\\.SemanticVersion\\{ \\.major = [0-9]+, \\.minor = [0-9]+, \\.patch = [0-9]+ \\};/const libspore_version = std.SemanticVersion{ .major = ${MAJOR}, .minor = ${MINOR}, .patch = ${PATCH} };/; s/\\\\\\\\Version: [0-9]+\\.[0-9]+\\.[0-9]+/\\\\\\\\Version: ${VERSION}/" build.zig

grep -Fq "pub const value = \"${VERSION}\";" src/version.zig \
  || die "failed to update src/version.zig"
grep -Fq "const libspore_version = std.SemanticVersion{ .major = ${MAJOR}, .minor = ${MINOR}, .patch = ${PATCH} };" build.zig \
  || die "failed to update build.zig libspore_version"
grep -Fq "\\\\Version: ${VERSION}" build.zig \
  || die "failed to update build.zig pkg-config version"

printf '[prepare-release] prepared %s\n' "${NEXT}"
