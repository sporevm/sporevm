#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
image="${SPORE_TTY_IMAGE:-docker.io/library/alpine:3.20}"
timeout_bin="${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"
[[ -n "${timeout_bin}" ]] || die "timeout binary not found"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-tty.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

set +e
"${spore_bin}" run -t --image "${image}" -- /bin/true >"${workdir}/raw.stdout" 2>"${workdir}/raw.stderr"
raw_rc="$?"
set -e
[[ "${raw_rc}" == "2" ]] || die "spore run -t with redirected stdout exited ${raw_rc}, expected 2"
grep -Fq "requires stdout to be a terminal" "${workdir}/raw.stderr" || {
  cat "${workdir}/raw.stderr" >&2 || true
  die "spore run -t did not reject redirected stdout with the expected message"
}

"${timeout_bin}" 60s "${spore_bin}" run -t --events=jsonl --image "${image}" -- \
  /bin/sh -lc 'stty size; printf "tty-ok\n"' >"${workdir}/events.jsonl" 2>"${workdir}/events.stderr"

[[ ! -s "${workdir}/events.stderr" ]] || {
  cat "${workdir}/events.stderr" >&2 || true
  die "spore run -t --events=jsonl wrote unexpected stderr"
}

python3 - "${workdir}/events.jsonl" <<'PY'
import base64
import json
import re
import sys

terminal = bytearray()
saw_exit = False
exit_code = None
with open(sys.argv[1], "rb") as f:
    for raw in f:
        event = json.loads(raw)
        if event.get("event") == "terminal":
            terminal.extend(base64.b64decode(event["data_base64"]))
        elif event.get("event") == "exit":
            saw_exit = True
            exit_code = event.get("exit_code")

data = bytes(terminal)
if b"tty-ok" not in data:
    raise SystemExit(f"terminal event payload missing tty-ok: {data!r}")
if re.search(rb"(^|\r?\n)[0-9]+ [0-9]+(\r?\n|$)", data) is None:
    raise SystemExit(f"terminal event payload missing stty size: {data!r}")
if not saw_exit or exit_code != 0:
    raise SystemExit(f"missing successful exit event: saw_exit={saw_exit} exit_code={exit_code!r}")
PY

echo "smoke:run-tty ok"
