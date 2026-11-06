#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-net-deny"

set +e
"${spore_bin}" --debug run --net --events=jsonl -- /bin/wget -qO- http://169.254.169.254/ >"${workdir}/wget.stdout" 2>"${workdir}/wget.stderr"
wget_rc="$?"
set -e

if [[ "${wget_rc}" == "0" ]]; then
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore run --net unexpectedly reached a hard-floor destination"
fi

# netd answers a denied SYN with an RST; without one, wget's connect times out
# after 5 s instead.
jsonl_output_contains "${workdir}/wget.stdout" stderr "Connection refused" || {
  cat "${workdir}/wget.stdout" >&2 || true
  die "denied connect was not refused"
}

grep -Fq "denied egress" "${workdir}/wget.stderr" || {
  cat "${workdir}/wget.stderr" >&2 || true
  die "debug log did not include denied egress"
}

grep -Fq "169.254.169.254:80" "${workdir}/wget.stderr" || {
  cat "${workdir}/wget.stderr" >&2 || true
  die "debug log did not include denied destination"
}

grep -Fq '"event":"network"' "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  die "event stream did not include network event"
}

grep -Fq '"type":"egress_denied"' "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  die "event stream did not include denied egress type"
}

grep -Fq '"destination_ip":"169.254.169.254"' "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  die "event stream did not include denied destination"
}

echo "smoke:run-net-deny ok"
