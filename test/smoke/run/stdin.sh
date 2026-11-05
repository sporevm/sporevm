#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
image="${SPORE_STDIN_IMAGE:-docker.io/library/alpine:3.20}"
timeout_bin="${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}"

require_spore_bin
[[ -n "${timeout_bin}" ]] || die "timeout binary not found"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-stdin"

printf hi | "${spore_bin}" run -i --image "${image}" -- /bin/cat >"${workdir}/interactive.stdout" 2>"${workdir}/interactive.stderr"
grep -Fxq "hi" "${workdir}/interactive.stdout" || {
  cat "${workdir}/interactive.stdout" >&2 || true
  die "spore run -i did not forward stdin to guest stdout"
}
[[ ! -s "${workdir}/interactive.stderr" ]] || {
  cat "${workdir}/interactive.stderr" >&2 || true
  die "spore run -i wrote unexpected stderr"
}

printf hi | "${timeout_bin}" 30s "${spore_bin}" run --image "${image}" -- /bin/sh -lc 'if read x; then printf "read:%s\n" "$x"; else printf "eof\n"; fi' >"${workdir}/default.stdout" 2>"${workdir}/default.stderr"
grep -Fxq "eof" "${workdir}/default.stdout" || {
  cat "${workdir}/default.stdout" >&2 || true
  die "spore run without -i did not leave guest stdin at EOF"
}
[[ ! -s "${workdir}/default.stderr" ]] || {
  cat "${workdir}/default.stderr" >&2 || true
  die "spore run without -i wrote unexpected stderr"
}

printf hi | "${spore_bin}" run -i --events=jsonl --image "${image}" -- /bin/cat >"${workdir}/events.jsonl" 2>"${workdir}/events.stderr"
grep -Fq '"event":"stdout"' "${workdir}/events.jsonl" || {
  cat "${workdir}/events.jsonl" >&2 || true
  die "spore run -i --events=jsonl did not emit stdout event"
}
grep -Fq '"data_base64":"aGk="' "${workdir}/events.jsonl" || {
  cat "${workdir}/events.jsonl" >&2 || true
  die "spore run -i --events=jsonl stdout payload did not match stdin"
}
grep -Fq '"event":"completion","outcome":"completed"' "${workdir}/events.jsonl" || {
  cat "${workdir}/events.jsonl" >&2 || true
  die "spore run -i --events=jsonl did not emit a completed completion event"
}
[[ ! -s "${workdir}/events.stderr" ]] || {
  cat "${workdir}/events.stderr" >&2 || true
  die "spore run -i --events=jsonl wrote unexpected stderr"
}

echo "smoke:run-stdin ok"
