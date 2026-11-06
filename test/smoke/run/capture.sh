#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-run-capture"

capture_dir="${workdir}/captured.spore"
fork_dir="${workdir}/children"
from_base_dir="${workdir}/from-base.spore"
from_base_fork_dir="${workdir}/from-base-children"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
resume_stdout="${workdir}/resume.stdout"
resume_stderr="${workdir}/resume.stderr"
from_stdout="${workdir}/from.stdout"
from_stderr="${workdir}/from.stderr"
from_child_stdout="${workdir}/from-child.stdout"
from_child_stderr="${workdir}/from-child.stderr"
from_generation_json="${workdir}/from-generation.json"
from_generation_stdout="${workdir}/from-generation.stdout"
from_generation_stderr="${workdir}/from-generation.stderr"
from_base_stdout="${workdir}/from-base.stdout"
from_base_stderr="${workdir}/from-base.stderr"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --save "${capture_dir}" \
  --save-on USR1 \
  -- /bin/finite \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_ready=0
for _ in $(seq 1 "${SPORE_SMOKE_CAPTURE_POLLS:-120}"); do
  if grep -Fxq "spore finite ready" "${run_stdout}"; then
    seen_ready=1
    break
  fi
  sleep "${SPORE_SMOKE_CAPTURE_POLL_INTERVAL:-0.1}"
done
if [[ "${seen_ready}" != "1" ]]; then
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
  wait "${run_pid}" >/dev/null 2>&1 || true
  tail -80 "${run_stderr}" >&2 || true
  die "spore run save smoke did not reach the long-running command"
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
  die "spore run save exited ${run_rc}, expected 0"
fi
[[ -f "${capture_dir}/manifest.json" ]] || die "save did not write ${capture_dir}/manifest.json"
grep -Fq "saved spore at ${capture_dir}" "${run_stderr}" || {
  cat "${run_stderr}" >&2 || true
  die "spore run save did not report the save path"
}

"${spore_bin}" checkpoint fork "${capture_dir}" --count 1 --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"
children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(fork_children "${fork_dir}")
[[ "${#children[@]}" -eq 1 ]] || die "fork did not create one child spore"
child_dir="${children[0]}"

"${spore_bin}" --json attach --backend "${backend}" "${child_dir}" >"${resume_stdout}" 2>"${resume_stderr}" &
resume_pid="$!"
(
  sleep "${SPORE_SMOKE_RESUME_TIMEOUT_SECONDS:-20}"
  kill -TERM "${resume_pid}" >/dev/null 2>&1 || true
) &
watchdog_pid="$!"

set +e
wait "${resume_pid}"
resume_rc="$?"
set -e
kill "${watchdog_pid}" >/dev/null 2>&1 || true
wait "${watchdog_pid}" >/dev/null 2>&1 || true

if [[ "${resume_rc}" != "0" ]]; then
  cat "${resume_stdout}" >&2 || true
  cat "${resume_stderr}" >&2 || true
  die "spore --json attach exited ${resume_rc}, expected 0"
fi
grep -Fq '"event":"ready"' "${resume_stdout}" || die "spore --json attach did not emit ready"
grep -Fq '"event":"stdout"' "${resume_stdout}" || die "spore --json attach did not emit stdout"
grep -Fq '"event":"completion","outcome":"completed"' "${resume_stdout}" || die "spore --json attach did not emit completed terminal outcome"
grep -Fq '"exit_code":0' "${resume_stdout}" || die "spore --json attach did not report exit_code 0"
grep -Fq '"memory_restore_source":"local_backing"' "${resume_stdout}" || die "spore --json attach did not report local RAM restore"
grep -Fq '"memory_restore_reason":"proof_valid"' "${resume_stdout}" || die "spore --json attach did not report proof-backed restore"

# A guest that powers off before its command exits has no exit status, so run
# and attach must fail with ProbeDidNotComplete rather than report exit 0.
expect_probe_incomplete() {
  local label="$1" rc="$2" jsonl="$3" stderr="$4"
  [[ "${rc}" != "0" ]] && grep -Fq '"source":"ProbeDidNotComplete"' "${jsonl}" && return
  cat "${jsonl}" "${stderr}" >&2 || true
  die "${label} of a guest that powers off exited ${rc} without ProbeDidNotComplete"
}
set +e
with_timeout 60 "${spore_bin}" --json run --backend "${backend}" --memory "${smoke_memory}" -- /bin/poweroff \
  >"${workdir}/poweroff-run.jsonl" 2>"${workdir}/poweroff-run.stderr"
poweroff_rc="$?"
set -e
expect_probe_incomplete "spore run" "${poweroff_rc}" "${workdir}/poweroff-run.jsonl" "${workdir}/poweroff-run.stderr"

# The guest powers itself off 5 s in; the watchdog stops the run if it hangs.
# Backgrounding `with_timeout` would put a bash subshell, not spore, behind
# `$!`, and USR1 would kill that subshell instead of saving.
poweroff_dir="${workdir}/poweroff.spore"
"${spore_bin}" run --backend "${backend}" --memory "${smoke_memory}" \
  --save "${poweroff_dir}" --save-on USR1 -- /bin/poweroff 5 \
  >"${workdir}/poweroff-save.stdout" 2>"${workdir}/poweroff-save.stderr" &
run_pid="$!"
(
  sleep 60
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
) &
watchdog_pid="$!"
for _ in $(seq 1 "${SPORE_SMOKE_CAPTURE_POLLS:-120}"); do
  grep -Fxq "spore poweroff ready" "${workdir}/poweroff-save.stdout" && break
  sleep "${SPORE_SMOKE_CAPTURE_POLL_INTERVAL:-0.1}"
done
sleep "${SPORE_SMOKE_CAPTURE_SETTLE_SECONDS:-0.3}"
kill -USR1 "${run_pid}" || true
set +e
wait "${run_pid}"
run_rc="$?"
set -e
kill "${watchdog_pid}" >/dev/null 2>&1 || true
wait "${watchdog_pid}" >/dev/null 2>&1 || true
[[ "${run_rc}" == "0" && -f "${poweroff_dir}/manifest.json" ]] || {
  cat "${workdir}/poweroff-save.stderr" >&2 || true
  die "spore run did not save the guest before it powered off (exit ${run_rc})"
}
set +e
with_timeout 60 "${spore_bin}" --json attach --backend "${backend}" "${poweroff_dir}" \
  >"${workdir}/poweroff-attach.jsonl" 2>"${workdir}/poweroff-attach.stderr"
poweroff_rc="$?"
set -e
expect_probe_incomplete "spore attach" "${poweroff_rc}" "${workdir}/poweroff-attach.jsonl" "${workdir}/poweroff-attach.stderr"

# Two vCPUs: the first command after restoring a finished multi-vCPU guest
# once hung on a lost wakeup.
"${spore_bin}" run \
  --backend "${backend}" \
  --vcpus 2 \
  --memory "${smoke_memory}" \
  --save "${from_base_dir}" \
  -- /bin/true \
  >"${from_base_stdout}" 2>"${from_base_stderr}"
[[ -f "${from_base_dir}/manifest.json" ]] || die "run --from base save did not write ${from_base_dir}/manifest.json"

"${spore_bin}" checkpoint fork "${from_base_dir}" --count 1 --out "${from_base_fork_dir}" >"${workdir}/from-base-fork.stdout" 2>"${workdir}/from-base-fork.stderr"
from_child_dir="$(fork_children "${from_base_fork_dir}" | head -n 1)"
[[ -n "${from_child_dir}" ]] || die "forked run --from base did not create a child spore"

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${from_child_dir}" \
  -- /bin/gencheck \
  >"${from_child_stdout}" 2>"${from_child_stderr}" || {
  cat "${from_child_stdout}" >&2 || true
  cat "${from_child_stderr}" >&2 || true
  die "forked spore run --from generation check failed"
}
grep -Fq "spore generation ready " "${from_child_stdout}" || {
  cat "${from_child_stdout}" >&2 || true
  cat "${from_child_stderr}" >&2 || true
  die "forked spore run --from did not start after generation metadata"
}
grep -Fq "entropy_len=32" "${from_child_stdout}" || {
  cat "${from_child_stdout}" >&2 || true
  cat "${from_child_stderr}" >&2 || true
  die "forked spore run --from did not expose resume entropy"
}

cat >"${from_generation_json}" <<'JSON'
{"run_id":"run-from-generation-smoke","child_id":7,"parallel_index":7,"parallel_count":1000,"fork_index":7,"fork_count":1000,"fork_batch_id":"run-from-generation-batch","vm_id":"spore-run-from-generation-7","generation":7007,"resume_entropy_seed":"0123456789abcdef0123456789abcdef"}
JSON
"${spore_bin}" run \
  --backend "${backend}" \
  --from "${from_child_dir}" \
  --generation "${from_generation_json}" \
  -- /bin/gencheck \
  >"${from_generation_stdout}" 2>"${from_generation_stderr}" || {
  cat "${from_generation_stdout}" >&2 || true
  cat "${from_generation_stderr}" >&2 || true
  die "forked spore run --from --generation check failed"
}
grep -Fq "generation=7007 vm_id=spore-run-from-generation-7 entropy_len=32" "${from_generation_stdout}" || {
  cat "${from_generation_stdout}" >&2 || true
  cat "${from_generation_stderr}" >&2 || true
  die "forked spore run --from --generation did not expose explicit generation metadata"
}

"${spore_bin}" --json --debug run \
  --backend "${backend}" \
  --from "${from_base_dir}" \
  -- /bin/writeout \
  >"${from_stdout}" 2>"${from_stderr}"
jsonl_output_contains "${from_stdout}" stdout "spore stdout" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not emit stdout"
}
jsonl_output_contains "${from_stdout}" stderr "spore stderr" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not emit stderr"
}
grep -Fq '"memory_restore_source":"local_backing"' "${from_stdout}" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not report local RAM restore"
}
grep -Fq '"memory_restore_reason":"proof_valid"' "${from_stdout}" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not report proof-backed restore"
}

echo "smoke:run-capture ok backend=${backend}"
