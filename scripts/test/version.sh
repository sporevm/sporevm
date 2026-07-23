#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[test-version] error: %s\n' "$*" >&2
  exit 1
}

prefix="${1:-zig-out}"
expected_mode="${2:-}"
binary="${prefix}/bin/spore"
pc_file="${prefix}/lib/pkgconfig/libspore.pc"
source_version="$(sed -nE 's/^pub const value = "([^"]+)";$/\1/p' src/version.zig)"

[[ -n "${source_version}" ]] || die "cannot read src/version.zig"
[[ -x "${binary}" ]] || die "missing binary: ${binary}"
[[ -f "${pc_file}" ]] || die "missing pkg-config metadata: ${pc_file}"

version_output="$(env -i "${binary}" --version)"
case "${version_output}" in
  "spore ${source_version} (Debug)"|"spore ${source_version} (ReleaseSafe)") ;;
  *) die "unexpected --version output: ${version_output}" ;;
esac

if [[ -n "${expected_mode}" && "${version_output}" != "spore ${source_version} (${expected_mode})" ]]; then
  die "expected ${expected_mode} output, got: ${version_output}"
fi

[[ "$(sed -nE 's/^Version: (.+)$/\1/p' "${pc_file}")" == "${source_version}" ]] \
  || die "pkg-config version does not match ${source_version}"
[[ "$("${binary}" version)" == "${version_output}" ]] \
  || die "legacy version command disagrees with --version"

"${binary}" --help | grep -Fq -- '--version' \
  || die "global help does not advertise --version"

printf '[test-version] %s agrees with source and pkg-config metadata\n' "${version_output}"
