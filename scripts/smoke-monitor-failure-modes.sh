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

run_capture() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2

  set +e
  "$@" >"${stdout_path}" 2>"${stderr_path}"
  local status=$?
  set -e
  return "${status}"
}

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
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-monitor-fail.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-mon-fail.XXXXXX")"
rootfs_cache_dir="${SPORE_MONITOR_FAILURE_ROOTFS_CACHE_DIR:-${SPOREVM_ROOTFS_CACHE_DIR:-${workdir}/rootfs-cache}}"
mkdir -p "${rootfs_cache_dir}"
chmod 700 "${runtime_dir}" 2>/dev/null || true

rootfs_vm="fail-rootfs-${backend}-$$"
dead_vm="fail-dead-${backend}-$$"
rootfs_created=0
dead_created=0
failed=0

run_spore() {
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_ROOTFS_CACHE_DIR="${rootfs_cache_dir}" "${spore_bin}" "$@"
}

cleanup() {
  if [[ "${failed}" == "1" && -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:monitor-failure-modes kept workdir=${workdir} runtime_dir=${runtime_dir}" >&2
    return
  fi
  if [[ "${rootfs_created}" == "1" ]]; then
    run_spore rm "${rootfs_vm}" >/dev/null 2>&1 || true
  fi
  if [[ "${dead_created}" == "1" ]]; then
    run_spore rm "${dead_vm}" >/dev/null 2>&1 || true
  fi
  rm -rf "${runtime_dir}"
  rm -rf "${workdir}"
}
trap cleanup EXIT

memory="${SPORE_MONITOR_FAILURE_MEMORY:-512mb}"
dead_memory="${SPORE_MONITOR_FAILURE_DEAD_MEMORY:-256mib}"
timeout_ms="${SPORE_MONITOR_FAILURE_TIMEOUT_MS:-120000}"
image="${SPORE_MONITOR_FAILURE_IMAGE:-docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271}"
console_log="${workdir}/rootfs-console.log"

if run_capture "${workdir}/create.out" "${workdir}/create.err" \
  run_spore create "${rootfs_vm}" \
    --backend "${backend}" \
    --memory "${memory}" \
    --timeout "${timeout_ms}ms" \
    --console-log "${console_log}" \
    --image "${image}"; then
  rootfs_created=1
else
  failed=1
  cat "${workdir}/create.err" >&2 || true
  die "spore create rootfs VM failed"
fi

if run_capture "${workdir}/sigterm.out" "${workdir}/sigterm.err" \
  run_spore exec "${rootfs_vm}" -- /bin/sh -lc 'kill -TERM $$'; then
  failed=1
  die "guest SIGTERM command unexpectedly exited 0"
else
  sigterm_status=$?
fi
[[ "${sigterm_status}" == "143" ]] || {
  failed=1
  cat "${workdir}/sigterm.err" >&2 || true
  die "guest SIGTERM returned ${sigterm_status}, expected 143"
}

if run_capture "${workdir}/sigkill.out" "${workdir}/sigkill.err" \
  run_spore exec "${rootfs_vm}" -- /bin/sh -lc 'kill -KILL $$'; then
  failed=1
  die "guest SIGKILL command unexpectedly exited 0"
else
  sigkill_status=$?
fi
[[ "${sigkill_status}" == "137" ]] || {
  failed=1
  cat "${workdir}/sigkill.err" >&2 || true
  die "guest SIGKILL returned ${sigkill_status}, expected 137"
}

oom_js='const chunks=[]; let i=0; for (;;) { chunks.push(Buffer.alloc(64*1024*1024, 1)); console.error("allocated_64mib_chunks=" + (++i)); }'
if run_capture "${workdir}/oom.out" "${workdir}/oom.err" \
  run_spore exec "${rootfs_vm}" -- /bin/sh -lc "node -e '${oom_js}'"; then
  failed=1
  die "guest OOM command unexpectedly exited 0"
else
  oom_status=$?
fi
[[ "${oom_status}" == "137" ]] || {
  failed=1
  cat "${workdir}/oom.err" >&2 || true
  die "guest OOM returned ${oom_status}, expected 137"
}
grep -Eiq 'out of memory|oom-kill|killed process' "${console_log}" || {
  failed=1
  cat "${workdir}/oom.err" >&2 || true
  tail -100 "${console_log}" >&2 || true
  die "guest console did not include OOM evidence"
}

if ! run_spore exec "${rootfs_vm}" -- /bin/true; then
  failed=1
  die "rootfs VM did not remain usable after guest OOM"
fi
if ! run_spore rm "${rootfs_vm}"; then
  failed=1
  die "spore rm rootfs VM failed after guest OOM"
fi
rootfs_created=0

if run_capture "${workdir}/dead-create.out" "${workdir}/dead-create.err" \
  run_spore create "${dead_vm}" --backend "${backend}" --memory "${dead_memory}" --timeout 60s; then
  dead_created=1
else
  failed=1
  cat "${workdir}/dead-create.err" >&2 || true
  die "spore create diskless VM failed"
fi

pid_path="${runtime_dir}/vms/${dead_vm}/pid"
[[ -s "${pid_path}" ]] || {
  failed=1
  die "monitor pid file missing or empty: ${pid_path}"
}
monitor_pid="$(tr -d '[:space:]' <"${pid_path}")"
[[ "${monitor_pid}" =~ ^[0-9]+$ ]] || {
  failed=1
  die "monitor pid file did not contain a numeric pid: ${pid_path}"
}
kill -TERM "${monitor_pid}" 2>/dev/null || true
if ! wait_dead "${monitor_pid}"; then
  kill -KILL "${monitor_pid}" 2>/dev/null || true
  wait_dead "${monitor_pid}" || {
    failed=1
    die "monitor pid did not exit after SIGKILL: ${monitor_pid}"
  }
fi

if run_capture "${workdir}/dead-exec.out" "${workdir}/dead-exec.err" \
  run_spore exec "${dead_vm}" -- /bin/true; then
  failed=1
  die "exec against killed monitor unexpectedly exited 0"
else
  dead_exec_status=$?
fi
[[ "${dead_exec_status}" == "2" ]] || {
  failed=1
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor returned ${dead_exec_status}, expected 2"
}
grep -q "state=stale" "${workdir}/dead-exec.err" || {
  failed=1
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report stale VM state"
}
grep -q "console_log=" "${workdir}/dead-exec.err" || {
  failed=1
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report console log path"
}
grep -q "monitor_log=" "${workdir}/dead-exec.err" || {
  failed=1
  cat "${workdir}/dead-exec.err" >&2 || true
  die "exec against killed monitor did not report monitor log path"
}

if ! run_spore rm "${dead_vm}"; then
  failed=1
  die "spore rm killed monitor VM failed"
fi
dead_created=0
[[ ! -e "${runtime_dir}/vms/${dead_vm}" ]] || {
  failed=1
  die "spore rm did not clean killed monitor state"
}

echo "smoke:monitor-failure-modes ok backend=${backend} sigterm=${sigterm_status} sigkill=${sigkill_status} oom=${oom_status} killed-monitor-exec=${dead_exec_status}"
