#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-net"

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
