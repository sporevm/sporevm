#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net-deny.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" --debug run --net -- /bin/wget -qO- http://169.254.169.254/ >"${workdir}/wget.stdout" 2>"${workdir}/wget.stderr"
wget_rc="$?"
set -e

if [[ "${wget_rc}" == "0" ]]; then
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore run --net unexpectedly reached a hard-floor destination"
fi

grep -Fq "denied egress" "${workdir}/wget.stderr" || {
  cat "${workdir}/wget.stderr" >&2 || true
  die "debug log did not include denied egress"
}

grep -Fq "169.254.169.254:80" "${workdir}/wget.stderr" || {
  cat "${workdir}/wget.stderr" >&2 || true
  die "debug log did not include denied destination"
}

echo "smoke:run-net-deny ok"
