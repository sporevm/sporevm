#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
backend="$(infer_backend)"
require_spore_bin
smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-timeouts"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-timeouts"
export SPOREVM_RUNTIME_DIR="${runtime_dir}"
vm_name="timeouts-${backend}-$$"
created=0
cleanup() {
  if [[ "${created}" == 1 ]]; then
    "${spore_bin}" vm rm "${vm_name}" >/dev/null 2>&1 || true
  fi
}

"${spore_bin}" vm create "${vm_name}" --backend "${backend}" \
  --startup-timeout 60s --exec-timeout 200ms \
  --shell 'while true; do echo initial-alive; sleep 1; done' >"${workdir}/create.stdout"
created=1

if run_capture "${workdir}/timeout.stdout" "${workdir}/timeout.stderr" \
  "${spore_bin}" vm exec "${vm_name}" --shell \
  '(sleep 2; touch /tmp/timeout-orphan) & wait'; then
  die "command exceeded its execution limit without failing"
else
  status=$?
  [[ "${status}" == 1 ]] || die "execution timeout returned ${status}, expected 1"
fi
grep -Fq 'execution timed out' "${workdir}/timeout.stderr" || die "missing timeout phase"
sleep 3
"${spore_bin}" vm exec --exec-timeout 5s "${vm_name}" --shell \
  'test ! -e /tmp/timeout-orphan && echo descendants-stopped' >"${workdir}/recovery.stdout"
grep -Fxq descendants-stopped "${workdir}/recovery.stdout" || die "timed-out descendant survived"

# The override must not replace the VM's default. The same command succeeds
# without a limit, then fails in JSON mode with the inherited 200ms limit.
"${spore_bin}" vm exec "${vm_name}" --exec-timeout none --shell \
  'sleep 1; echo unlimited-done' >"${workdir}/unlimited.stdout"
grep -Fxq unlimited-done "${workdir}/unlimited.stdout" || die "none did not disable execution timeout"
if run_capture "${workdir}/timeout.jsonl" "${workdir}/timeout-json.stderr" \
  "${spore_bin}" --json vm exec "${vm_name}" --shell 'sleep 2'; then
  die "per-exec override changed the VM default"
else
  status=$?
  [[ "${status}" == 1 ]] || die "JSON execution timeout returned ${status}, expected 1"
fi
python3 - "${workdir}/timeout.jsonl" <<'PY'
import json
import sys
events = [json.loads(line) for line in open(sys.argv[1])]
completion, = [event for event in events if event["event"] == "completion"]
assert completion["exit_code"] == 1, completion
assert completion["error"]["code"] == "runtime.execution_failed", completion
assert "execution timed out" in completion["error"]["message"], completion
PY
"${spore_bin}" vm exec "${vm_name}" --exec-timeout 5s -- /bin/true
"${spore_bin}" vm logs "${vm_name}" --initial >"${workdir}/initial.stdout"
grep -Fq initial-alive "${workdir}/initial.stdout" || die "timeout removed the initial process"
echo "scoped timeouts: descendants stopped, overrides isolated, named VM retained"
