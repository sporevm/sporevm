#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

jsonl_output_contains() {
  python3 - "$1" "$2" "$3" <<'PY'
import base64
import json
import sys

needle = sys.argv[3].encode()
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") != sys.argv[2]:
            continue
        if needle in base64.b64decode(event.get("data_base64", "")):
            sys.exit(0)
sys.exit(1)
PY
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

"${spore_bin}" fork "${capture_dir}" --count 1 --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"
children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(find "${fork_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#children[@]}" -eq 1 ]] || die "fork did not create one child spore"
child_dir="${children[0]}"

"${spore_bin}" attach --events=jsonl --backend "${backend}" "${child_dir}" >"${resume_stdout}" 2>"${resume_stderr}" &
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
  die "spore attach --events=jsonl exited ${resume_rc}, expected 0"
fi
grep -Fq '"event":"ready"' "${resume_stdout}" || die "spore attach --events=jsonl did not emit ready"
grep -Fq '"event":"stdout"' "${resume_stdout}" || die "spore attach --events=jsonl did not emit stdout"
grep -Fq '"event":"completion","outcome":"completed"' "${resume_stdout}" || die "spore attach --events=jsonl did not emit completed terminal outcome"
grep -Fq '"exit_code":0' "${resume_stdout}" || die "spore attach --events=jsonl did not report exit_code 0"
grep -Fq '"memory_restore_source":"local_backing"' "${resume_stdout}" || die "spore attach --events=jsonl did not report local RAM restore"
grep -Fq '"memory_restore_reason":"proof_valid"' "${resume_stdout}" || die "spore attach --events=jsonl did not report proof-backed restore"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --save "${from_base_dir}" \
  -- /bin/true \
  >"${from_base_stdout}" 2>"${from_base_stderr}"
[[ -f "${from_base_dir}/manifest.json" ]] || die "run --from base save did not write ${from_base_dir}/manifest.json"

"${spore_bin}" fork "${from_base_dir}" --count 1 --out "${from_base_fork_dir}" >"${workdir}/from-base-fork.stdout" 2>"${workdir}/from-base-fork.stderr"
from_child_dir="$(find "${from_base_fork_dir}" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
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

"${spore_bin}" --debug run \
  --backend "${backend}" \
  --events=jsonl \
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
