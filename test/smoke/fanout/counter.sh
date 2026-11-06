#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_spore_bin

count="${SPORE_SMOKE_FANOUT_COUNT:-10}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_FANOUT_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_FANOUT_COUNT must be greater than zero"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-counter-fanout"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-counter"
named_vm="cf-$$"
run_pid=""
resume_pid=""
watchdog_pid=""
cleanup() {
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${named_vm}" >/dev/null 2>&1 || true
  if [[ -n "${run_pid}" ]]; then
    kill -TERM "${run_pid}" >/dev/null 2>&1 || true
    wait "${run_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${resume_pid}" ]]; then
    kill -TERM "${resume_pid}" >/dev/null 2>&1 || true
    wait "${resume_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${watchdog_pid}" ]]; then
    kill "${watchdog_pid}" >/dev/null 2>&1 || true
    wait "${watchdog_pid}" >/dev/null 2>&1 || true
  fi
}

capture_dir="${workdir}/counter.spore"
fork_dir="${workdir}/children"
generation_fork_dir="${workdir}/generation-children"
generation_json="${workdir}/generation.json"
generation_resume_stdout="${workdir}/generation-resume.stdout"
generation_resume_stderr="${workdir}/generation-resume.stderr"
named_resume_stdout="${workdir}/named-resume.stdout"
named_resume_stderr="${workdir}/named-resume.stderr"
named_exec_stdout="${workdir}/named-exec.stdout"
named_exec_stderr="${workdir}/named-exec.stderr"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
fanout_stdout="${workdir}/fanout.stdout"
fanout_stderr="${workdir}/fanout.stderr"

"${spore_bin}" run \
  --backend "${backend}" \
  --save "${capture_dir}" \
  --save-on USR1 \
  -- /bin/counter \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_counter=0
for _ in $(seq 1 "${SPORE_SMOKE_CAPTURE_POLLS:-120}"); do
  if grep -Eaq 'spore counter [0-9]+' "${run_stdout}"; then
    seen_counter=1
    break
  fi
  sleep "${SPORE_SMOKE_CAPTURE_POLL_INTERVAL:-0.1}"
done
if [[ "${seen_counter}" != "1" ]]; then
  tail -80 "${run_stderr}" >&2 || true
  die "counter fan-out smoke did not see the fresh counter"
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
run_pid=""
kill "${watchdog_pid}" >/dev/null 2>&1 || true
wait "${watchdog_pid}" >/dev/null 2>&1 || true
watchdog_pid=""

if [[ "${run_rc}" != "0" ]]; then
  cat "${run_stdout}" >&2 || true
  cat "${run_stderr}" >&2 || true
  die "spore run capture exited ${run_rc}, expected 0"
fi
[[ -f "${capture_dir}/manifest.json" ]] || die "capture did not write ${capture_dir}/manifest.json"

"${spore_bin}" fork "${capture_dir}" --count 1 --out "${generation_fork_dir}" >"${workdir}/generation-fork.stdout" 2>"${workdir}/generation-fork.stderr"
cat >"${generation_json}" <<'JSON'
{"run_id":"counter-smoke","child_id":7,"parallel_index":7,"parallel_count":1000,"fork_index":7,"fork_count":1000,"fork_batch_id":"counter-smoke-batch","vm_id":"spore-counter-smoke-7","generation":7,"resume_entropy_seed":"0123456789abcdef0123456789abcdef"}
JSON

"${spore_bin}" --json attach --generation "${generation_json}" --backend "${backend}" "${generation_fork_dir}/000000" \
  >"${generation_resume_stdout}" 2>"${generation_resume_stderr}" &
resume_pid="$!"

seen_generation=0
for _ in $(seq 1 "${SPORE_SMOKE_GENERATION_POLLS:-120}"); do
  if ! kill -0 "${resume_pid}" >/dev/null 2>&1; then
    break
  fi
  if jsonl_output_contains "${generation_resume_stdout}" stdout 'spore parallel job 7/1000'; then
    seen_generation=1
    break
  fi
  sleep "${SPORE_SMOKE_GENERATION_POLL_INTERVAL:-0.1}"
done
kill -TERM "${resume_pid}" >/dev/null 2>&1 || true
wait "${resume_pid}" >/dev/null 2>&1 || true
resume_pid=""

if [[ "${seen_generation}" != "1" ]]; then
  cat "${generation_resume_stdout}" >&2 || true
  cat "${generation_resume_stderr}" >&2 || true
  die "spore attach --generation did not inject guest fan-out identity"
fi
grep -Fq '"event":"ready"' "${generation_resume_stdout}" || die "spore --json attach --generation did not emit ready"
grep -Fq '"event":"stdout"' "${generation_resume_stdout}" || die "spore --json attach --generation did not emit stdout"

if ! env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json restore --generation "${generation_json}" --backend "${backend}" "${generation_fork_dir}/000000" --name "${named_vm}" \
  >"${named_resume_stdout}" 2>"${named_resume_stderr}"; then
  cat "${named_resume_stdout}" >&2 || true
  cat "${named_resume_stderr}" >&2 || true
  die "named spore restore --generation failed"
fi
[[ "$(json_field "${named_resume_stdout}" schema)" == "spore.lifecycle.v1" && "$(json_field "${named_resume_stdout}" state)" == "ready" ]] ||
  die "named spore --json restore --generation did not report a ready VM"
if ! env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${named_vm}" -- /bin/gencheck \
  >"${named_exec_stdout}" 2>"${named_exec_stderr}"; then
  cat "${named_exec_stdout}" >&2 || true
  cat "${named_exec_stderr}" >&2 || true
  die "named restored child exec generation check failed"
fi
grep -Fq "spore generation ready " "${named_exec_stdout}" || {
  cat "${named_exec_stdout}" >&2 || true
  cat "${named_exec_stderr}" >&2 || true
  die "named resumed child exec did not observe generation metadata"
}
env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${named_vm}" >/dev/null

"${spore_bin}" fork "${capture_dir}" --count "${count}" --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"

children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(fork_children "${fork_dir}")
[[ "${#children[@]}" == "${count}" ]] || die "expected ${count} child spores, found ${#children[@]}"

set +e
"${spore_bin}" fanout --backend "${backend}" "${fork_dir}" --for "${SPORE_SMOKE_FANOUT_DURATION:-20s}" \
  >"${fanout_stdout}" 2>"${fanout_stderr}"
fanout_rc="$?"
set -e

if [[ "${fanout_rc}" != "0" ]]; then
  cat "${fanout_stdout}" >&2 || true
  cat "${fanout_stderr}" >&2 || true
  die "spore fanout exited ${fanout_rc}, expected 0"
fi

# Each child resumes the saved process: its first counter line is the one after
# the last the saving run printed, with nothing replayed or lost.
saved_counter="$(grep -Eao 'spore counter [0-9]+' "${run_stdout}" | tail -n 1 | awk '{print $NF}')"
for child in "${children[@]}"; do
  child_name="$(basename "${child}")"
  child_index="$((10#${child_name}))"
  if ! grep -Eaq "^\[${child_name}\] spore parallel job ${child_index}/${count}" "${fanout_stdout}"; then
    tail -160 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "child ${child_name} did not report SPORE_PARALLEL_JOB=${child_index} SPORE_PARALLEL_JOB_COUNT=${count}"
  fi
  first_counter="$(grep -Ea "^\[${child_name}\] " "${fanout_stdout}" | grep -Eao 'spore counter [0-9]+' | head -n 1 | awk '{print $NF}')"
  if [[ -z "${first_counter}" || "${first_counter}" != "$((saved_counter + 1))" ]]; then
    tail -120 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "child ${child_name} did not continue the counter from the saved run's last line"
  fi
done

echo "smoke:counter-fanout ok backend=${backend} count=${count}"
