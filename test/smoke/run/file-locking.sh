#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-file-locking"

set +e
"${spore_bin}" run -- /bin/flockcheck >"${workdir}/stdout" 2>"${workdir}/stderr"
rc="$?"
set -e

if [[ "${rc}" != "0" ]]; then
  cat "${workdir}/stdout" >&2 || true
  cat "${workdir}/stderr" >&2 || true
  die "spore run /bin/flockcheck exited ${rc}, expected 0"
fi

grep -Fxq "flock ok" "${workdir}/stdout" || {
  cat "${workdir}/stdout" >&2 || true
  cat "${workdir}/stderr" >&2 || true
  die "spore run /bin/flockcheck did not report successful file locking"
}

echo "smoke:run-file-locking ok"
