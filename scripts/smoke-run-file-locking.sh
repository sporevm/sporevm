#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-file-locking.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

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
