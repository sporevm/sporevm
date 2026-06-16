#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

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

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-capture.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

capture_dir="${workdir}/captured.spore"
from_base_dir="${workdir}/from-base.spore"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
resume_log="${workdir}/resume.log"
from_stdout="${workdir}/from.stdout"
from_stderr="${workdir}/from.stderr"
from_base_stdout="${workdir}/from-base.stdout"
from_base_stderr="${workdir}/from-base.stderr"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory-mib "${SPORE_SMOKE_MEMORY_MIB:-256}" \
  --capture "${capture_dir}" \
  --capture-on USR1 \
  -- /bin/sleeper \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_ready=0
for _ in $(seq 1 "${SPORE_SMOKE_CAPTURE_POLLS:-120}"); do
  if grep -Fxq "spore run ready" "${run_stdout}"; then
    seen_ready=1
    break
  fi
  sleep "${SPORE_SMOKE_CAPTURE_POLL_INTERVAL:-0.1}"
done
if [[ "${seen_ready}" != "1" ]]; then
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
  wait "${run_pid}" >/dev/null 2>&1 || true
  tail -80 "${run_stderr}" >&2 || true
  die "spore run capture smoke did not reach the long-running command"
fi

sleep "${SPORE_SMOKE_CAPTURE_SETTLE_SECONDS:-0.3}"
kill -USR1 "${run_pid}"

(
  sleep "${SPORE_SMOKE_CAPTURE_TIMEOUT_SECONDS:-20}"
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
) &
watchdog_pid="$!"

set +e
wait "${run_pid}"
run_rc="$?"
set -e
kill "${watchdog_pid}" >/dev/null 2>&1 || true
wait "${watchdog_pid}" >/dev/null 2>&1 || true

if [[ "${run_rc}" != "0" ]]; then
  cat "${run_stdout}" >&2 || true
  cat "${run_stderr}" >&2 || true
  die "spore run capture exited ${run_rc}, expected 0"
fi
[[ -f "${capture_dir}/manifest.json" ]] || die "capture did not write ${capture_dir}/manifest.json"
grep -Fq "captured snapshot at ${capture_dir}" "${run_stderr}" || {
  cat "${run_stderr}" >&2 || true
  die "spore run capture did not report the capture path"
}

"${spore_bin}" resume --backend "${backend}" "${capture_dir}" >"${resume_log}" 2>&1 &
resume_pid="$!"
seen_resume_output=0
for _ in $(seq 1 "${SPORE_SMOKE_RESUME_POLLS:-120}"); do
  if grep -Eaq 'spore sleeper tick [0-9]+' "${resume_log}"; then
    seen_resume_output=1
    break
  fi
  sleep "${SPORE_SMOKE_RESUME_POLL_INTERVAL:-0.1}"
done

kill -TERM "${resume_pid}" >/dev/null 2>&1 || true
sleep 0.2
kill -KILL "${resume_pid}" >/dev/null 2>&1 || true
wait "${resume_pid}" >/dev/null 2>&1 || true

if [[ "${seen_resume_output}" != "1" ]]; then
  tail -80 "${resume_log}" >&2 || true
  die "product resume did not stream output from the captured run spore"
fi

"${spore_bin}" run \
  --backend "${backend}" \
  --memory-mib "${SPORE_SMOKE_MEMORY_MIB:-256}" \
  --capture "${from_base_dir}" \
  -- /bin/true \
  >"${from_base_stdout}" 2>"${from_base_stderr}"
[[ -f "${from_base_dir}/manifest.json" ]] || die "run --from base capture did not write ${from_base_dir}/manifest.json"

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${from_base_dir}" \
  -- /bin/writeout \
  >"${from_stdout}" 2>"${from_stderr}"
grep -Fq "spore stdout" "${from_stdout}" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not stream stdout"
}
grep -Fq "spore stderr" "${from_stderr}" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not stream stderr"
}

echo "smoke:run-capture ok backend=${backend}"
