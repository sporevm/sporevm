#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-cgroup"

set +e
"${spore_bin}" run -- /bin/cgroupcheck >"${workdir}/stdout" 2>"${workdir}/stderr"
rc="$?"
set -e

if [[ "${rc}" != "0" ]]; then
  cat "${workdir}/stdout" >&2 || true
  cat "${workdir}/stderr" >&2 || true
  die "spore run /bin/cgroupcheck exited ${rc}, expected 0"
fi

grep -Fxq "cgroup ok" "${workdir}/stdout" || {
  cat "${workdir}/stdout" >&2 || true
  cat "${workdir}/stderr" >&2 || true
  die "spore run /bin/cgroupcheck did not report successful cgroup setup"
}

echo "smoke:run-cgroup ok"
