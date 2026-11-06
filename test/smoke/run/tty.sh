#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
image="${SPORE_TTY_IMAGE:-docker.io/library/alpine:3.20}"

require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-tty"

set +e
"${spore_bin}" run -t --image "${image}" -- /bin/true >"${workdir}/raw.stdout" 2>"${workdir}/raw.stderr"
raw_rc="$?"
set -e
[[ "${raw_rc}" == "2" ]] || die "spore run -t with redirected stdout exited ${raw_rc}, expected 2"
grep -Fq "requires stdout to be a terminal" "${workdir}/raw.stderr" || {
  cat "${workdir}/raw.stderr" >&2 || true
  die "spore run -t did not reject redirected stdout with the expected message"
}

with_timeout 60 "${spore_bin}" --json run -t --image "${image}" -- \
  /bin/sh -lc 'stty size; printf "tty-ok\n"' >"${workdir}/events.jsonl" 2>"${workdir}/events.stderr"

[[ ! -s "${workdir}/events.stderr" ]] || {
  cat "${workdir}/events.stderr" >&2 || true
  die "spore --json run -t wrote unexpected stderr"
}

python3 - "${workdir}/events.jsonl" <<'PY'
import base64
import json
import re
import sys

terminal = bytearray()
saw_completion = False
exit_code = None
with open(sys.argv[1], "rb") as f:
    for raw in f:
        event = json.loads(raw)
        if event.get("event") == "terminal":
            terminal.extend(base64.b64decode(event["data_base64"]))
        elif event.get("event") == "completion" and event.get("outcome") == "completed":
            saw_completion = True
            exit_code = event.get("exit_code")

data = bytes(terminal)
if b"tty-ok" not in data:
    raise SystemExit(f"terminal event payload missing tty-ok: {data!r}")
if re.search(rb"(^|\r?\n)[0-9]+ [0-9]+(\r?\n|$)", data) is None:
    raise SystemExit(f"terminal event payload missing stty size: {data!r}")
if not saw_completion or exit_code != 0:
    raise SystemExit(f"missing successful completion event: saw_completion={saw_completion} exit_code={exit_code!r}")
PY

echo "smoke:run-tty ok"
