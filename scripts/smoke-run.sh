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
"${spore_bin}" run -- /bin/echo spore-smoke >"${workdir}/echo.stdout" 2>"${workdir}/echo.stderr"
echo_rc="$?"
set -e
[[ "${echo_rc}" == "0" ]] || {
  cat "${workdir}/echo.stderr" >&2 || true
  die "spore run /bin/echo exited ${echo_rc}, expected 0"
}
grep -Fxq "spore-smoke" "${workdir}/echo.stdout" || {
  cat "${workdir}/echo.stdout" >&2 || true
  die "spore run /bin/echo did not forward guest stdout"
}

set +e
"${spore_bin}" run 'echo spore-shell-smoke' >"${workdir}/shell.stdout" 2>"${workdir}/shell.stderr"
shell_rc="$?"
set -e
[[ "${shell_rc}" == "0" ]] || {
  cat "${workdir}/shell.stderr" >&2 || true
  die "spore run shell command exited ${shell_rc}, expected 0"
}
grep -Fxq "spore-shell-smoke" "${workdir}/shell.stdout" || {
  cat "${workdir}/shell.stdout" >&2 || true
  die "spore run shell command did not forward guest stdout"
}

set +e
"${spore_bin}" run -- echo spore-smoke >"${workdir}/bare.stdout" 2>"${workdir}/bare.stderr"
bare_rc="$?"
set -e
[[ "${bare_rc}" == "127" ]] || {
  cat "${workdir}/bare.stderr" >&2 || true
  die "spore run bare echo exited ${bare_rc}, expected 127"
}
grep -Fq "spore run: exact argv command \"echo\" was not found." "${workdir}/bare.stderr" || {
  cat "${workdir}/bare.stderr" >&2 || true
  die "spore run bare echo did not explain exact argv lookup"
}

set +e
"${spore_bin}" run -- /bin/not-there >"${workdir}/missing.stdout" 2>"${workdir}/missing.stderr"
missing_rc="$?"
set -e
[[ "${missing_rc}" == "127" ]] || {
  cat "${workdir}/missing.stderr" >&2 || true
  die "spore run missing initrd command exited ${missing_rc}, expected 127"
}
grep -Fq "spore run: initrd cannot execute /bin/not-there: not found; use --image, --rootfs, or provide an initrd containing the command" "${workdir}/missing.stderr" || {
  cat "${workdir}/missing.stderr" >&2 || true
  die "spore run missing initrd command did not explain the failure"
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
