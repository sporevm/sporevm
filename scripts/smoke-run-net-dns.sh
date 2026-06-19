#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net-dns.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" run --net -- /bin/nslookup example.com >"${workdir}/nslookup.stdout" 2>"${workdir}/nslookup.stderr"
nslookup_rc="$?"
set -e

if [[ "${nslookup_rc}" != "0" ]]; then
  cat "${workdir}/nslookup.stdout" >&2 || true
  cat "${workdir}/nslookup.stderr" >&2 || true
  die "spore run --net /bin/nslookup exited ${nslookup_rc}, expected 0"
fi

grep -Fq "Address:" "${workdir}/nslookup.stdout" || {
  cat "${workdir}/nslookup.stdout" >&2 || true
  cat "${workdir}/nslookup.stderr" >&2 || true
  die "spore nslookup did not print an address"
}

echo "smoke:run-net-dns ok"
