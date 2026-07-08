#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net-http.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" run --net -- /bin/wget -qO- http://example.com/ >"${workdir}/wget.stdout" 2>"${workdir}/wget.stderr"
wget_rc="$?"
set -e

if [[ "${wget_rc}" != "0" ]]; then
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore run --net /bin/wget exited ${wget_rc}, expected 0"
fi

grep -Fq "Example Domain" "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore wget did not fetch the expected body"
}

echo "smoke:run-net-http ok"
