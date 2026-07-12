#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Benchmark hot-cache image saves or first-save migration from a portable spore.

Usage:
  scripts/benchmark/hot-run-save.sh [options]

Options:
  --spore-bin PATH          Spore binary (default: zig-out/bin/spore)
  --backend kvm|hvf|auto    Backend (default: auto)
  --image REF               Image (default: node:22-bookworm-slim)
  --portable-parent DIR     Start from a self-contained local-CAS spore, then
                            report first migration separately from repeats.
  --memory VALUE            Guest memory (default: 1024mb)
  --iterations N            Timed captures (default: 5)
  --cache-dir PATH          Rootfs cache (default: benchmark workdir/cache)
  --work-dir PATH           Parent for temporary run state and save outputs.
                            Existing path; default: TMPDIR or /tmp.
  --output PATH             JSONL output (default: benchmark workdir/results.jsonl)
  --strace-output PATH      Linux only: write `strace -f -c` syscall summary.
                            Use one iteration for a focused profile.
  --allow-full-scan         Permit a versioned full scan; do not enforce the
                            dirty-bounded disk snapshot metric.
  --keep-workdir            Keep per-run spores and logs.
  --self-test               Verify benchmark-owned runtime directory privacy.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  [[ -n "${2-}" ]] || die "$1 requires a value"
}

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1000000)'
}

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

device_id() {
  if stat -f '%d' "$1" >/dev/null 2>&1; then
    stat -f '%d' "$1"
  else
    stat -c '%d' "$1"
  fi
}

private_dir_mode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

ensure_private_runtime_dir() {
  local path="$1"
  mkdir -p "${path}"
  chmod 0700 "${path}"
  [[ "$(private_dir_mode "${path}")" == "700" ]] || \
    die "benchmark runtime directory is not mode 0700: ${path}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
spore_bin="${repo_root}/zig-out/bin/spore"
backend="auto"
image="docker.io/library/node:22-bookworm-slim"
portable_parent=""
memory="1024mb"
iterations=5
cache_dir=""
work_dir="${TMPDIR:-/tmp}"
output=""
strace_output=""
allow_full_scan=0
keep_workdir=0
self_test=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spore-bin) need_value "$1" "${2-}"; spore_bin="$2"; shift 2 ;;
    --backend) need_value "$1" "${2-}"; backend="$2"; shift 2 ;;
    --image) need_value "$1" "${2-}"; image="$2"; shift 2 ;;
    --portable-parent) need_value "$1" "${2-}"; portable_parent="$2"; shift 2 ;;
    --memory) need_value "$1" "${2-}"; memory="$2"; shift 2 ;;
    --iterations) need_value "$1" "${2-}"; iterations="$2"; shift 2 ;;
    --cache-dir) need_value "$1" "${2-}"; cache_dir="$2"; shift 2 ;;
    --work-dir) need_value "$1" "${2-}"; work_dir="$2"; shift 2 ;;
    --output) need_value "$1" "${2-}"; output="$2"; shift 2 ;;
    --strace-output) need_value "$1" "${2-}"; strace_output="$2"; shift 2 ;;
    --allow-full-scan) allow_full_scan=1; shift ;;
    --keep-workdir) keep_workdir=1; shift ;;
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ "${self_test}" == "1" ]]; then
  self_test_root="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-hot-run-save-self-test.XXXXXX")"
  trap 'rm -rf "${self_test_root}"' EXIT
  umask 022
  ensure_private_runtime_dir "${self_test_root}/runtime"
  [[ "$(private_dir_mode "${self_test_root}/runtime")" == "700" ]] || \
    die "runtime directory privacy self-test failed"
  echo "hot-run-save runtime directory self-test ok"
  exit 0
fi

[[ -x "${spore_bin}" ]] || die "spore binary is not executable: ${spore_bin}"
[[ "${iterations}" =~ ^[1-9][0-9]*$ ]] || die "--iterations must be positive"

[[ -d "${work_dir}" ]] || die "--work-dir must be an existing directory: ${work_dir}"
workdir="$(mktemp -d "${work_dir%/}/sporevm-hot-run-save.XXXXXX")"
if [[ -z "${cache_dir}" ]]; then cache_dir="${workdir}/cache"; fi
if [[ -z "${output}" ]]; then output="${workdir}/results.jsonl"; fi
mkdir -p "${cache_dir}" "$(dirname "${output}")"
: >"${output}"

cleanup() {
  if [[ -n "${named_vm-}" && -x "${debug_wrapper-}" ]]; then
    "${debug_wrapper}" rm "${named_vm}" >/dev/null 2>&1 || true
  fi
  if [[ -x "${debug_wrapper-}" ]]; then
    for saved in "${saved_outputs[@]-}"; do
      [[ -n "${saved}" ]] && "${debug_wrapper}" rm --spore "${saved}" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${keep_workdir}" == "1" ]]; then
    echo "kept benchmark workdir: ${workdir}" >&2
  else
    rm -rf "${workdir}"
  fi
}
trap cleanup EXIT

export SPOREVM_ROOTFS_CACHE_DIR="${cache_dir}"
export SPOREVM_ROOTFS_BUILD_PROFILE=1

if [[ -n "${portable_parent}" ]]; then
  [[ "${iterations}" -ge 2 ]] || die "--portable-parent requires at least two iterations"
  [[ -z "$(find "${cache_dir}" -mindepth 1 -print -quit)" ]] || \
    die "--portable-parent requires an empty migration cache: ${cache_dir}"
  validation_cache="${workdir}/validation-cache"
  validation_runtime="${workdir}/validation-runtime"
  validation_bundle="${workdir}/validated-input.bundle"
  mkdir -p "${validation_cache}"
  ensure_private_runtime_dir "${validation_runtime}"
  env SPOREVM_ROOTFS_CACHE_DIR="${validation_cache}" SPOREVM_RUNTIME_DIR="${validation_runtime}" \
    "${spore_bin}" pack "${portable_parent}" --out "${validation_bundle}" >/dev/null || \
    die "portable parent failed product pack verification"
  provenance="$(python3 "${repo_root}/scripts/benchmark/portable-spore-provenance.py" \
    --spore-dir "${portable_parent}" --spore-bin "${spore_bin}")" || die "portable parent provenance validation failed"
  printf '{"phase":"provenance","lane":"portable_first_migration","source_device":%s,"cache_device":%s,"same_filesystem":%s,"input":%s}\n' \
    "$(device_id "${portable_parent}")" "$(device_id "${cache_dir}")" \
    "$(if [[ "$(device_id "${portable_parent}")" == "$(device_id "${cache_dir}")" ]]; then echo true; else echo false; fi)" \
    "${provenance}" >>"${output}"
  export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
  ensure_private_runtime_dir "${SPOREVM_RUNTIME_DIR}"
  debug_wrapper="${workdir}/spore-debug"
  printf '#!/usr/bin/env bash\nexec -a "$0" %q --debug "$@"\n' "${spore_bin}" >"${debug_wrapper}"
  chmod 0700 "${debug_wrapper}"
  named_vm="portable-migration"
  saved_outputs=()
  restore_start="$(now_ms)"
  "${debug_wrapper}" restore "${portable_parent}" --name "${named_vm}" --backend "${backend}" >/dev/null
  restore_ms="$(( $(now_ms) - restore_start ))"
  printf '{"phase":"warm","duration_ms":%d,"source":%s,"consumer":"named_restore"}\n' \
    "${restore_ms}" "$(json_string "${portable_parent}")" >>"${output}"
  monitor_log="${SPOREVM_RUNTIME_DIR}/vms/${named_vm}/monitor.log"

  for iteration in $(seq 1 "${iterations}"); do
    save_dir="${workdir}/save-${iteration}.spore"
    saved_outputs+=("${save_dir}")
    "${debug_wrapper}" exec "${named_vm}" "printf '%s\\n' '${iteration}' > /sporevm-migration-marker" >/dev/null
    disk_lines_before="$(grep -c 'disk snapshot metrics:' "${monitor_log}" || true)"
    snapshot_lines_before="$(grep -Ec '(kvm|hvf) snapshot metrics:' "${monitor_log}" || true)"
    publication_lines_before="$(grep -Ec '(kvm|hvf) named snapshot publication metrics:' "${monitor_log}" || true)"
    start_ms="$(now_ms)"
    "${debug_wrapper}" save "${named_vm}" --out "${save_dir}" >/dev/null
    duration_ms="$(( $(now_ms) - start_ms ))"
    [[ "$(grep -c 'disk snapshot metrics:' "${monitor_log}" || true)" -eq "$((disk_lines_before + 1))" ]] || \
      die "iteration ${iteration} did not append exactly one disk metric"
    [[ "$(grep -Ec '(kvm|hvf) snapshot metrics:' "${monitor_log}" || true)" -eq "$((snapshot_lines_before + 1))" ]] || \
      die "iteration ${iteration} did not append exactly one snapshot metric"
    [[ "$(grep -Ec '(kvm|hvf) named snapshot publication metrics:' "${monitor_log}" || true)" -eq "$((publication_lines_before + 1))" ]] || \
      die "iteration ${iteration} did not append exactly one publication metric"
    lane="$(if [[ "${iteration}" == "1" ]]; then echo first_migration; else echo steady_cache_backed; fi)"
    disk_metrics_line="$(grep 'disk snapshot metrics:' "${monitor_log}" | tail -n 1 || true)"
    snapshot_metrics_line="$(grep -E '(kvm|hvf) snapshot metrics:' "${monitor_log}" | tail -n 1 || true)"
    publication_metrics_line="$(grep -E '(kvm|hvf) named snapshot publication metrics:' "${monitor_log}" | tail -n 1 || true)"
    [[ -n "${disk_metrics_line}" ]] || die "iteration ${iteration} did not report disk snapshot metrics"
    [[ -n "${snapshot_metrics_line}" ]] || die "iteration ${iteration} did not report backend snapshot metrics"
    [[ -n "${publication_metrics_line}" ]] || die "iteration ${iteration} did not report named publication metrics"
    disk_metrics="$(python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" "${disk_metrics_line}")" || \
      die "iteration ${iteration} reported malformed disk snapshot metrics"
    snapshot_metrics="$(python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" --snapshot "${snapshot_metrics_line}")" || \
      die "iteration ${iteration} reported malformed backend snapshot metrics"
    publication_metrics="$(python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" --named-publication "${publication_metrics_line}")" || \
      die "iteration ${iteration} reported malformed named publication metrics"
    full_scan="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["full_scan"]).lower())' "${disk_metrics}")"
    if [[ "${allow_full_scan}" != "1" && "${full_scan}" != "false" ]]; then
      die "iteration ${iteration} did not report a dirty-bounded disk snapshot: ${disk_metrics}"
    fi
    python3 - "${iteration}" "${duration_ms}" "${lane}" "${disk_metrics}" "${snapshot_metrics}" "${publication_metrics}" "${save_dir}" >>"${output}" <<'PY'
import json
import sys

iteration, duration_ms, lane, disk_raw, snapshot_raw, publication_raw, save_dir = sys.argv[1:]
disk = json.loads(disk_raw)
snapshot = json.loads(snapshot_raw)
publication = json.loads(publication_raw)
migrated_objects = disk["parent_objects_linked"] + disk["parent_objects_copied"]
migrated_bytes = disk["parent_link_bytes"] + disk["parent_copy_bytes"]
if lane == "first_migration":
    if migrated_objects == 0 or migrated_bytes == 0:
        raise SystemExit("first migration did not publish portable parent objects")
elif migrated_objects != 0:
    raise SystemExit("steady cache-backed save republished parent objects")
print(json.dumps({
    "phase": "capture",
    "iteration": int(iteration),
    "lane": lane,
    "duration_ms": int(duration_ms),
    "migrated_objects": migrated_objects,
    "migrated_bytes": migrated_bytes,
    "parent_objects_reused": disk["parent_objects_reused"],
    "snapshot_capture_ms": snapshot["snapshot_total_ms"],
    "publication_pause_ms": publication["source_pause_ms"],
    "disk_metrics": disk,
    "snapshot_metrics": snapshot,
    "publication_metrics": publication,
    "save_dir": save_dir,
}, sort_keys=True, separators=(",", ":")))
PY
  done
  cat "${output}"
  exit 0
fi

warm_stdout="${workdir}/warm.stdout"
warm_stderr="${workdir}/warm.stderr"
warm_start="$(now_ms)"
"${spore_bin}" run --backend "${backend}" --memory "${memory}" --image "${image}" -- /bin/true >"${warm_stdout}" 2>"${warm_stderr}"
warm_ms="$(( $(now_ms) - warm_start ))"
printf '{"phase":"warm","duration_ms":%d,"source":%s}\n' "${warm_ms}" "$(json_string "${image}")" >>"${output}"

marker="SPOREVM_NODE_READY"
for iteration in $(seq 1 "${iterations}"); do
  save_dir="${workdir}/save-${iteration}.spore"
  events_pipe="${workdir}/events-${iteration}.pipe"
  stdout_path="${workdir}/save-${iteration}.stdout"
  stderr_path="${workdir}/save-${iteration}.stderr"
  mkfifo "${events_pipe}"

  start_ms="$(now_ms)"
  spore_args=(--debug run --events=jsonl --backend "${backend}" --memory "${memory}" --image "${image}")
  lane="steady_cache_backed"
  spore_args+=(--save "${save_dir}" --save-on USR1 -- /bin/sh -lc "trap '' USR1; node -v >/dev/null; echo ${marker}; sleep 300")
  if [[ -n "${strace_output}" ]]; then
    command -v strace >/dev/null || die "--strace-output requires strace"
    summary_path="${strace_output}"
    if [[ "${iterations}" != "1" ]]; then summary_path="${strace_output}.${iteration}"; fi
    exec 9<>"${events_pipe}"
    strace -f -c -o "${summary_path}" "${spore_bin}" "${spore_args[@]}" \
      >"${events_pipe}" 2>"${stderr_path}" &
    wait_pid=$!
    capture_pid=""
    for _ in $(seq 1 100); do
      capture_pid="$(pgrep -P "${wait_pid}" | head -n 1 || true)"
      [[ -n "${capture_pid}" ]] && break
      sleep 0.01
    done
    [[ -n "${capture_pid}" ]] || die "strace did not start the spore child"
    python3 "${repo_root}/scripts/internal/capture-on-output-marker.py" \
      --pid "${capture_pid}" --signal USR1 --event stdout --contains "${marker}" \
      --out "${stdout_path}" 9>&- <"${events_pipe}" &
    marker_pid=$!
    exec 9>&-
    wait "${wait_pid}"
    wait "${marker_pid}"
  else
    "${spore_bin}" "${spore_args[@]}" >"${events_pipe}" 2>"${stderr_path}" &
    capture_pid=$!
    wait_pid="${capture_pid}"
    python3 "${repo_root}/scripts/internal/capture-on-output-marker.py" \
      --pid "${capture_pid}" --signal USR1 --event stdout --contains "${marker}" \
      --out "${stdout_path}" <"${events_pipe}"
    wait "${wait_pid}"
  fi
  duration_ms="$(( $(now_ms) - start_ms ))"
  rm -f "${events_pipe}"

  disk_metrics_line="$(grep 'disk snapshot metrics:' "${stderr_path}" | tail -n 1 || true)"
  [[ -n "${disk_metrics_line}" ]] || die "iteration ${iteration} did not report disk snapshot metrics"
  disk_metrics="$(python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" "${disk_metrics_line}")" || \
    die "iteration ${iteration} reported malformed disk snapshot metrics"
  snapshot_metrics_line="$(grep -E '(kvm|hvf) snapshot metrics:' "${stderr_path}" | tail -n 1 || true)"
  [[ -n "${snapshot_metrics_line}" ]] || die "iteration ${iteration} did not report backend snapshot metrics"
  snapshot_metrics="$(python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" --snapshot "${snapshot_metrics_line}")" || \
    die "iteration ${iteration} reported malformed backend snapshot metrics"
  full_scan="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["full_scan"]).lower())' "${disk_metrics}")"
  if [[ "${allow_full_scan}" != "1" && "${full_scan}" != "false" ]]; then
    die "iteration ${iteration} did not report a dirty-bounded disk snapshot: ${disk_metrics}"
  fi
  python3 - "${iteration}" "${duration_ms}" "${lane}" "${disk_metrics}" "${snapshot_metrics}" "${save_dir}" >>"${output}" <<'PY'
import json
import sys

iteration, duration_ms, lane, disk_raw, snapshot_raw, save_dir = sys.argv[1:]
disk = json.loads(disk_raw)
snapshot = json.loads(snapshot_raw)
print(json.dumps({
    "phase": "capture",
    "iteration": int(iteration),
    "lane": lane,
    "duration_ms": int(duration_ms),
    "snapshot_capture_ms": snapshot["snapshot_total_ms"],
    "disk_metrics": disk,
    "snapshot_metrics": snapshot,
    "save_dir": save_dir,
}, sort_keys=True, separators=(",", ":")))
PY
done

cat "${output}"
