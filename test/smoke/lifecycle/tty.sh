#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
image="${SPORE_LIFECYCLE_TTY_IMAGE:-docker.io/library/alpine:3.20}"

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle-tty"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-life-tty"

vm_name="life-tty-${backend}-$$"
created=0
cleanup() {
  if [[ "${created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${vm_name}" >/dev/null 2>&1 || true
  fi
}

smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
timeout_ms="${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}"
console_log="${workdir}/console.log"

create_stdout="${workdir}/create.stdout"
create_stderr="${workdir}/create.stderr"
interactive_stdout="${workdir}/interactive.stdout"
interactive_stderr="${workdir}/interactive.stderr"
bounded_stdout="${workdir}/bounded.stdout"
bounded_stderr="${workdir}/bounded.stderr"
streamed_stdout="${workdir}/streamed.stdout"
streamed_stderr="${workdir}/streamed.stderr"
tty_stdout="${workdir}/tty.stdout"
tty_stderr="${workdir}/tty.stderr"

if run_capture "${create_stdout}" "${create_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm create "${vm_name}" \
    --backend "${backend}" \
    --image "${image}" \
    --memory "${smoke_memory}" \
    --timeout "${timeout_ms}ms" \
    --console-log "${console_log}"; then
  created=1
else
  status=$?
  require_success "${status}" "spore vm create" "${create_stderr}"
fi

if printf 'named-input\n' | run_capture "${interactive_stdout}" "${interactive_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec -i "${vm_name}" -- /bin/cat; then
  :
else
  status=$?
  require_success "${status}" "spore vm exec -i" "${interactive_stderr}"
fi
grep -Fxq "named-input" "${interactive_stdout}" || {
  cat "${interactive_stdout}" >&2 || true
  cat "${interactive_stderr}" >&2 || true
  die "spore vm exec -i did not forward stdin through the monitor stream"
}
[[ ! -s "${interactive_stderr}" ]] || {
  cat "${interactive_stderr}" >&2 || true
  die "spore vm exec -i wrote unexpected stderr"
}

if run_capture "${bounded_stdout}" "${bounded_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/sh -lc 'printf bounded-ok'; then
  :
else
  status=$?
  require_success "${status}" "plain spore vm exec after interactive exec" "${bounded_stderr}"
fi
grep -Fxq "bounded-ok" "${bounded_stdout}" || {
  cat "${bounded_stdout}" >&2 || true
  cat "${bounded_stderr}" >&2 || true
  die "plain spore vm exec did not work after interactive exec"
}

# Plain noninteractive exec must stream both output channels before exit and
# preserve more than 1 MiB byte-exactly on each channel. This reproduces the
# old buffered 16 KiB truncation failure with redirected automation output.
bulk_output_bytes=$((1536 * 1024))
set +e
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/sh -lc \
  "printf 'stdout-prompt\\n'; printf 'stderr-prompt\\n' >&2; sleep 2; head -c ${bulk_output_bytes} /dev/zero | tr '\\000' A; head -c ${bulk_output_bytes} /dev/zero | tr '\\000' B >&2; exit 7" \
  >"${streamed_stdout}" 2>"${streamed_stderr}" &
streamed_pid=$!
set -e

live_output=0
for _ in $(seq 1 50); do
  if grep -Fq "stdout-prompt" "${streamed_stdout}" && grep -Fq "stderr-prompt" "${streamed_stderr}"; then
    kill -0 "${streamed_pid}" 2>/dev/null || {
      die "plain spore vm exec delayed prompt output until command exit"
    }
    live_output=1
    break
  fi
  sleep 0.05
done
[[ "${live_output}" == "1" ]] || {
  die "plain spore vm exec did not stream prompt output"
}

set +e
wait "${streamed_pid}"
streamed_status=$?
set -e
[[ "${streamed_status}" == "7" ]] || {
  cat "${streamed_stderr}" >&2 || true
  die "plain streamed spore vm exec exited ${streamed_status}, expected 7"
}
python3 - "${streamed_stdout}" "${streamed_stderr}" "${bulk_output_bytes}" <<'PY'
import sys

stdout_path, stderr_path, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(stdout_path, "rb") as fh:
    stdout = fh.read()
with open(stderr_path, "rb") as fh:
    stderr = fh.read()
if stdout != b"stdout-prompt\n" + b"A" * size:
    raise SystemExit(f"stdout ordering/bytes mismatch: got {len(stdout)} bytes")
if stderr != b"stderr-prompt\n" + b"B" * size:
    raise SystemExit(f"stderr ordering/bytes mismatch: got {len(stderr)} bytes")
PY

if run_capture "${tty_stdout}" "${tty_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec -t "${vm_name}" -- /bin/sh -lc 'printf tty-out; printf tty-err >&2'; then
  :
else
  status=$?
  require_success "${status}" "redirected spore vm exec -t" "${tty_stderr}"
fi
grep -Fq "tty-out" "${tty_stdout}" && grep -Fq "tty-err" "${tty_stdout}" || {
  cat "${tty_stdout}" >&2 || true
  cat "${tty_stderr}" >&2 || true
  die "spore vm exec -t did not merge terminal output on redirected stdout"
}
[[ ! -s "${tty_stderr}" ]] || {
  cat "${tty_stderr}" >&2 || true
  die "spore vm exec -t wrote separate stderr output"
}

# Bulk exec stdio: over 1MiB must round-trip byte-exact through interactive
# exec stdin and streamed exec stdout. Historically the SPIO transport broke
# above one vsock packet, so tiny fixtures cannot cover this path.
bulk_bytes=$((1536 * 1024))
head -c "${bulk_bytes}" /dev/urandom >"${workdir}/bulk.bin"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec -i "${vm_name}" -- /bin/sh -c 'cat > /tmp/spore-exec-bulk.bin' \
  <"${workdir}/bulk.bin" || {
  die "bulk exec stdin transfer failed"
}
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec -i "${vm_name}" -- /bin/cat /tmp/spore-exec-bulk.bin \
  </dev/null >"${workdir}/bulk-stdout.bin" || {
  die "bulk exec stdout transfer failed"
}
cmp -s "${workdir}/bulk.bin" "${workdir}/bulk-stdout.bin" || {
  die "bulk exec stdio roundtrip mismatch"
}

# A deliberately failed stream must leave the VM usable: kill the CLI mid
# bulk stdin transfer, then require a follow-up exec to succeed.
( exec env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    "${spore_bin}" vm exec -i "${vm_name}" -- /bin/sh -c 'cat > /dev/null' \
    < <(head -c $((64 * 1024 * 1024)) /dev/zero) ) &
failed_stream_pid=$!
sleep 1
kill -KILL "${failed_stream_pid}" 2>/dev/null || true
wait "${failed_stream_pid}" 2>/dev/null || true
after_failed_stream="$(env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/sh -c 'echo usable')"
[[ "${after_failed_stream}" == "usable" ]] || {
  die "VM unusable after deliberately failed stream"
}

env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${vm_name}" >/dev/null || {
  die "named VM cleanup after streamed exec failed"
}
created=0
env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json vm ls >"${workdir}/after-rm.json"
python3 - "${workdir}/after-rm.json" "${vm_name}" <<'PY'
import json
import sys

path, removed = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)["entries"]
if any(entry.get("name") == removed for entry in entries):
    raise SystemExit(f"removed VM still listed: {removed}")
PY

echo "smoke:lifecycle-tty ok"
