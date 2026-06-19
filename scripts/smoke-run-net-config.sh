#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" run --net -- /bin/netcheck >"${workdir}/netcheck.stdout" 2>"${workdir}/netcheck.stderr"
netcheck_rc="$?"
set -e

if [[ "${netcheck_rc}" != "0" ]]; then
  cat "${workdir}/netcheck.stdout" >&2 || true
  cat "${workdir}/netcheck.stderr" >&2 || true
  die "spore run --net /bin/netcheck exited ${netcheck_rc}, expected 0"
fi

grep -Fq "spore-netcheck ok" "${workdir}/netcheck.stdout" || {
  cat "${workdir}/netcheck.stdout" >&2 || true
  cat "${workdir}/netcheck.stderr" >&2 || true
  die "spore netcheck did not report success"
}

echo "smoke:run-net-config ok"
