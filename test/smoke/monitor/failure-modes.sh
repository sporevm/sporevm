#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_dead() {
  local pid="$1"
  local i
  for i in $(seq 1 50); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-monitor-fail"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-mon-fail"
rootfs_cache_dir="${SPORE_MONITOR_FAILURE_ROOTFS_CACHE_DIR:-${SPOREVM_ROOTFS_CACHE_DIR:-${workdir}/rootfs-cache}}"
mkdir -p "${rootfs_cache_dir}"

rootfs_vm="fail-rootfs-${backend}-$$"
dead_vm="fail-dead-${backend}-$$"
rootfs_created=0
dead_created=0

run_spore() {
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_ROOTFS_CACHE_DIR="${rootfs_cache_dir}" "${spore_bin}" "$@"
}

cleanup() {
  if [[ "${rootfs_created}" == "1" ]]; then
    run_spore vm rm "${rootfs_vm}" >/dev/null 2>&1 || true
  fi
  if [[ "${dead_created}" == "1" ]]; then
    run_spore vm rm "${dead_vm}" >/dev/null 2>&1 || true
  fi
}

memory="${SPORE_MONITOR_FAILURE_MEMORY:-512mb}"
dead_memory="${SPORE_MONITOR_FAILURE_DEAD_MEMORY:-256mib}"
timeout_ms="${SPORE_MONITOR_FAILURE_TIMEOUT_MS:-120000}"
image="${SPORE_MONITOR_FAILURE_IMAGE:-docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271}"
console_log="${workdir}/rootfs-console.log"

if run_capture "${workdir}/create.out" "${workdir}/create.err" \
  run_spore vm create "${rootfs_vm}" \
    --backend "${backend}" \
    --memory "${memory}" \
    --timeout "${timeout_ms}ms" \
    --console-log "${console_log}" \
    --image "${image}"; then
  rootfs_created=1
else
  cat "${workdir}/create.err" >&2 || true
  die "spore vm create rootfs VM failed"
fi

if run_capture "${workdir}/sigterm.out" "${workdir}/sigterm.err" \
  run_spore vm exec "${rootfs_vm}" -- /bin/sh -lc 'kill -TERM $$'; then
  die "guest SIGTERM command unexpectedly exited 0"
else
  sigterm_status=$?
fi
[[ "${sigterm_status}" == "143" ]] || {
  cat "${workdir}/sigterm.err" >&2 || true
  die "guest SIGTERM returned ${sigterm_status}, expected 143"
}

if run_capture "${workdir}/sigkill.out" "${workdir}/sigkill.err" \
  run_spore vm exec "${rootfs_vm}" -- /bin/sh -lc 'kill -KILL $$'; then
  die "guest SIGKILL command unexpectedly exited 0"
else
  sigkill_status=$?
fi
[[ "${sigkill_status}" == "137" ]] || {
  cat "${workdir}/sigkill.err" >&2 || true
  die "guest SIGKILL returned ${sigkill_status}, expected 137"
}

oom_js='const chunks=[]; let i=0; for (;;) { chunks.push(Buffer.alloc(64*1024*1024, 1)); console.error("allocated_64mib_chunks=" + (++i)); }'
if run_capture "${workdir}/oom.out" "${workdir}/oom.err" \
  run_spore vm exec "${rootfs_vm}" -- /bin/sh -lc "node -e '${oom_js}'"; then
  die "guest OOM command unexpectedly exited 0"
else
  oom_status=$?
fi
[[ "${oom_status}" == "137" ]] || {
  cat "${workdir}/oom.err" >&2 || true
  die "guest OOM returned ${oom_status}, expected 137"
}
grep -Eiq 'out of memory|oom-kill|killed process' "${console_log}" || {
  cat "${workdir}/oom.err" >&2 || true
  tail -100 "${console_log}" >&2 || true
  die "guest console did not include OOM evidence"
}

if ! run_spore vm exec "${rootfs_vm}" -- /bin/true; then
  die "rootfs VM did not remain usable after guest OOM"
fi
if ! run_spore vm rm "${rootfs_vm}"; then
  die "spore vm rm rootfs VM failed after guest OOM"
fi
rootfs_created=0

# The killed VM has a network gateway, the helper most likely to outlive its
# monitor and keep a dead VM looking live.
if run_capture "${workdir}/dead-create.out" "${workdir}/dead-create.err" \
  run_spore vm create "${dead_vm}" --backend "${backend}" --memory "${dead_memory}" --timeout 60s --net; then
  dead_created=1
else
  cat "${workdir}/dead-create.err" >&2 || true
  die "spore vm create diskless VM failed"
fi

pid_path="${runtime_dir}/vms/${dead_vm}/pid"
[[ -s "${pid_path}" ]] || {
  die "monitor pid file missing or empty: ${pid_path}"
}
monitor_pid="$(tr -d '[:space:]' <"${pid_path}")"
[[ "${monitor_pid}" =~ ^[0-9]+$ ]] || {
  die "monitor pid file did not contain a numeric pid: ${pid_path}"
}
pgrep -g "${monitor_pid}" >/dev/null || die "monitor process group ${monitor_pid} is empty"
kill -KILL "${monitor_pid}"
wait_dead "${monitor_pid}" || die "monitor pid did not exit after SIGKILL: ${monitor_pid}"

dead_state=""
for _ in $(seq 1 20); do
  dead_state="$(run_spore --json vm ls | python3 -c 'import json, sys; print(next((e["state"] for e in json.load(sys.stdin)["entries"] if e["name"] == sys.argv[1]), "missing"))' "${dead_vm}")"
  [[ "${dead_state}" == "stale" ]] && break
  sleep 0.1
done
[[ "${dead_state}" == "stale" ]] || die "spore vm ls reported ${dead_state} for a VM whose monitor was killed, expected stale"

if run_capture "${workdir}/dead-exec.out" "${workdir}/dead-exec.err" \
  run_spore vm exec "${dead_vm}" -- /bin/true; then
  die "exec against killed monitor unexpectedly exited 0"
else
  dead_exec_status=$?
fi
[[ "${dead_exec_status}" == "2" ]] || {
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor returned ${dead_exec_status}, expected 2"
}
grep -q "state=stale" "${workdir}/dead-exec.err" || {
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report stale VM state"
}
grep -q "console_log=" "${workdir}/dead-exec.err" || {
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report console log path"
}
grep -q "monitor_log=" "${workdir}/dead-exec.err" || {
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report monitor log path"
}

if ! run_spore vm rm "${dead_vm}"; then
  die "spore vm rm killed monitor VM failed"
fi
dead_created=0
[[ ! -e "${runtime_dir}/vms/${dead_vm}" ]] || {
  die "spore vm rm did not clean killed monitor state"
}
for _ in $(seq 1 50); do
  pgrep -g "${monitor_pid}" >/dev/null || break
  sleep 0.1
done
if pgrep -g "${monitor_pid}" >/dev/null; then
  ps -o pid,pgid,command -p "$(pgrep -d, -g "${monitor_pid}")" >&2 || true
  die "processes from the killed monitor's group outlived it"
fi

echo "smoke:monitor-failure-modes ok backend=${backend} sigterm=${sigterm_status} sigkill=${sigkill_status} oom=${oom_status} killed-monitor-exec=${dead_exec_status} killed-monitor-state=${dead_state}"
