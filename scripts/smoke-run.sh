#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" run -- /bin/writeout >"${workdir}/writeout.stdout" 2>"${workdir}/writeout.stderr"
writeout_rc="$?"
set -e
[[ "${writeout_rc}" == "0" ]] || {
  cat "${workdir}/writeout.stderr" >&2 || true
  die "spore run /bin/writeout exited ${writeout_rc}, expected 0"
}
grep -Fxq "spore stdout" "${workdir}/writeout.stdout" || {
  cat "${workdir}/writeout.stdout" >&2 || true
  die "spore run /bin/writeout did not forward guest stdout"
}
grep -Fq "spore stderr" "${workdir}/writeout.stderr" || {
  cat "${workdir}/writeout.stderr" >&2 || true
  die "spore run /bin/writeout did not forward guest stderr"
}

set +e
"${spore_bin}" run -- /bin/false >"${workdir}/false.stdout" 2>"${workdir}/false.stderr"
false_rc="$?"
set -e
[[ "${false_rc}" == "1" ]] || die "spore run /bin/false exited ${false_rc}, expected 1"
[[ ! -s "${workdir}/false.stdout" ]] || {
  cat "${workdir}/false.stdout" >&2 || true
  die "spore run /bin/false wrote unexpected stdout"
}

set +e
"${spore_bin}" run --json -- /bin/true >"${workdir}/json.stdout" 2>"${workdir}/json.stderr"
json_rc="$?"
set -e
[[ "${json_rc}" == "2" ]] || die "spore run --json exited ${json_rc}, expected 2"
grep -Fq "unknown run argument: --json" "${workdir}/json.stderr" || {
  cat "${workdir}/json.stderr" >&2 || true
  die "spore run --json did not reject with the expected message"
}

echo "smoke:run ok"
