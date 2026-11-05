#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-net-dns"

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
