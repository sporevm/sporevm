#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
image="${SPORE_ATTACH_IMAGE:-docker.io/library/alpine:3.20}"
timeout_bin="${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}"

die() {
  echo "error: $*" >&2
  exit 1
}

infer_backend() {
  if [[ -n "${SPORE_BACKEND:-}" ]]; then
    echo "${SPORE_BACKEND}"
    return
  fi

  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "hvf" ;;
    Linux-aarch64|Linux-arm64) echo "kvm" ;;
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
  esac
}

jsonl_terminal_contains() {
  python3 - "$1" "$2" <<'PY'
import base64
import json
import sys

needle = sys.argv[2].encode()
terminal = bytearray()
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        event = json.loads(line)
        if event.get("event") == "terminal":
            terminal.extend(base64.b64decode(event.get("data_base64", "")))
if needle not in terminal:
    raise SystemExit(f"terminal payload missing {needle!r}: {bytes(terminal)!r}")
PY
}

jsonl_terminal_succeeds() {
  python3 - "$1" "$2" <<'PY'
import base64
import json
import sys

needle = sys.argv[2].encode()
terminal = bytearray()
exit_code = None
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        event = json.loads(line)
        if event.get("event") == "terminal":
            terminal.extend(base64.b64decode(event.get("data_base64", "")))
        elif event.get("event") == "exit":
            exit_code = event.get("exit_code")
if needle not in terminal:
    raise SystemExit(f"terminal payload missing {needle!r}: {bytes(terminal)!r}")
if exit_code != 0:
    raise SystemExit(f"missing successful exit event: exit_code={exit_code!r}")
PY
}

jsonl_failure_contains() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

needle = sys.argv[2]
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        event = json.loads(line)
        if event.get("event") != "failure":
            continue
        message = event.get("error", {}).get("message", "")
        if needle in message:
            sys.exit(0)
sys.exit(1)
PY
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"
[[ -n "${timeout_bin}" ]] || die "timeout binary not found"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-attach.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
tty_capture="${workdir}/live-tty.spore"
tty_run_jsonl="${workdir}/live-tty.jsonl"
tty_run_stderr="${workdir}/live-tty.stderr"
tty_attach_jsonl="${workdir}/attach-tty.jsonl"
tty_attach_stderr="${workdir}/attach-tty.stderr"
noninteractive_capture="${workdir}/noninteractive.spore"
reject_jsonl="${workdir}/reject.jsonl"
reject_stderr="${workdir}/reject.stderr"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  -t \
  --events=jsonl \
  --image "${image}" \
  --save "${tty_capture}" \
  --save-on USR1 \
  --continue-after-save \
  -- /bin/sh -lc 'i=0; while [ "$i" -lt 8 ]; do echo "tty-attach-tick:$i"; i=$((i + 1)); sleep 1; done' \
  >"${tty_run_jsonl}" 2>"${tty_run_stderr}" &
run_pid="$!"

seen_tick=0
for _ in $(seq 1 "${SPORE_SMOKE_ATTACH_POLLS:-160}"); do
  if jsonl_terminal_contains "${tty_run_jsonl}" "tty-attach-tick:0" >/dev/null 2>&1; then
    seen_tick=1
    break
  fi
  sleep "${SPORE_SMOKE_ATTACH_POLL_INTERVAL:-0.1}"
done
if [[ "${seen_tick}" != "1" ]]; then
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
  wait "${run_pid}" >/dev/null 2>&1 || true
  cat "${tty_run_jsonl}" >&2 || true
  cat "${tty_run_stderr}" >&2 || true
  die "live TTY run did not emit the first terminal tick"
fi

kill -USR1 "${run_pid}"
for _ in $(seq 1 "${SPORE_SMOKE_ATTACH_POLLS:-160}"); do
  [[ -f "${tty_capture}/manifest.json" ]] && break
  sleep "${SPORE_SMOKE_ATTACH_POLL_INTERVAL:-0.1}"
done
[[ -f "${tty_capture}/manifest.json" ]] || {
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
  wait "${run_pid}" >/dev/null 2>&1 || true
  cat "${tty_run_stderr}" >&2 || true
  die "live TTY capture did not write a manifest"
}

"${timeout_bin}" 60s "${spore_bin}" attach \
  --backend "${backend}" \
  -t \
  --events=jsonl \
  "${tty_capture}" \
  >"${tty_attach_jsonl}" 2>"${tty_attach_stderr}"

jsonl_terminal_succeeds "${tty_attach_jsonl}" "tty-attach-tick:" || {
  cat "${tty_attach_jsonl}" >&2 || true
  cat "${tty_attach_stderr}" >&2 || true
  die "TTY attach did not continue terminal output"
}

set +e
wait "${run_pid}"
run_rc="$?"
set -e
[[ "${run_rc}" == "0" ]] || {
  cat "${tty_run_jsonl}" >&2 || true
  cat "${tty_run_stderr}" >&2 || true
  die "original live TTY run exited ${run_rc}, expected 0"
}

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --save "${noninteractive_capture}" \
  -- /bin/true \
  >"${workdir}/noninteractive.stdout" 2>"${workdir}/noninteractive.stderr"
[[ -f "${noninteractive_capture}/manifest.json" ]] || die "non-interactive capture did not write a manifest"

set +e
printf 'input\n' | "${timeout_bin}" 30s "${spore_bin}" attach \
  --backend "${backend}" \
  -i \
  --events=jsonl \
  "${noninteractive_capture}" \
  >"${reject_jsonl}" 2>"${reject_stderr}"
reject_rc="$?"
set -e
[[ "${reject_rc}" == "2" ]] || {
  cat "${reject_jsonl}" >&2 || true
  cat "${reject_stderr}" >&2 || true
  die "non-interactive -i attach exited ${reject_rc}, expected 2"
}
jsonl_failure_contains "${reject_jsonl}" "saved session has no interactive stdin" || {
  cat "${reject_jsonl}" >&2 || true
  cat "${reject_stderr}" >&2 || true
  die "non-interactive -i attach did not report the expected error"
}

echo "smoke:run-attach ok backend=${backend}"
