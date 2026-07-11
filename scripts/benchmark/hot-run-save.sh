#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Benchmark hot-cache `spore run --image ... --save` capture.

Usage:
  scripts/benchmark/hot-run-save.sh [options]

Options:
  --spore-bin PATH          Spore binary (default: zig-out/bin/spore)
  --backend kvm|hvf|auto    Backend (default: auto)
  --image REF               Image (default: node:22-bookworm-slim)
  --memory VALUE            Guest memory (default: 1024mb)
  --iterations N            Timed captures (default: 5)
  --cache-dir PATH          Rootfs cache (default: benchmark workdir/cache)
  --work-dir PATH           Parent for temporary run state and save outputs.
                            Existing path; default: TMPDIR or /tmp.
  --output PATH             JSONL output (default: benchmark workdir/results.jsonl)
  --strace-output PATH      Linux only: write `strace -f -c` syscall summary.
                            Use one iteration for a focused profile.
  --allow-full-scan         Permit a schema-1 full scan; do not enforce the
                            dirty-bounded disk snapshot metric.
  --keep-workdir            Keep per-run spores and logs.
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
spore_bin="${repo_root}/zig-out/bin/spore"
backend="auto"
image="docker.io/library/node:22-bookworm-slim"
memory="1024mb"
iterations=5
cache_dir=""
work_dir="${TMPDIR:-/tmp}"
output=""
strace_output=""
allow_full_scan=0
keep_workdir=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spore-bin) need_value "$1" "${2-}"; spore_bin="$2"; shift 2 ;;
    --backend) need_value "$1" "${2-}"; backend="$2"; shift 2 ;;
    --image) need_value "$1" "${2-}"; image="$2"; shift 2 ;;
    --memory) need_value "$1" "${2-}"; memory="$2"; shift 2 ;;
    --iterations) need_value "$1" "${2-}"; iterations="$2"; shift 2 ;;
    --cache-dir) need_value "$1" "${2-}"; cache_dir="$2"; shift 2 ;;
    --work-dir) need_value "$1" "${2-}"; work_dir="$2"; shift 2 ;;
    --output) need_value "$1" "${2-}"; output="$2"; shift 2 ;;
    --strace-output) need_value "$1" "${2-}"; strace_output="$2"; shift 2 ;;
    --allow-full-scan) allow_full_scan=1; shift ;;
    --keep-workdir) keep_workdir=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "${spore_bin}" ]] || die "spore binary is not executable: ${spore_bin}"
[[ "${iterations}" =~ ^[1-9][0-9]*$ ]] || die "--iterations must be positive"

[[ -d "${work_dir}" ]] || die "--work-dir must be an existing directory: ${work_dir}"
workdir="$(mktemp -d "${work_dir%/}/sporevm-hot-run-save.XXXXXX")"
if [[ -z "${cache_dir}" ]]; then cache_dir="${workdir}/cache"; fi
if [[ -z "${output}" ]]; then output="${workdir}/results.jsonl"; fi
mkdir -p "${cache_dir}" "$(dirname "${output}")"
: >"${output}"

cleanup() {
  if [[ "${keep_workdir}" == "1" ]]; then
    echo "kept benchmark workdir: ${workdir}" >&2
  else
    rm -rf "${workdir}"
  fi
}
trap cleanup EXIT

export SPOREVM_ROOTFS_CACHE_DIR="${cache_dir}"
export SPOREVM_ROOTFS_BUILD_PROFILE=1

warm_stdout="${workdir}/warm.stdout"
warm_stderr="${workdir}/warm.stderr"
warm_start="$(now_ms)"
"${spore_bin}" run --backend "${backend}" --memory "${memory}" --image "${image}" -- /bin/true >"${warm_stdout}" 2>"${warm_stderr}"
warm_ms="$(( $(now_ms) - warm_start ))"
printf '{"phase":"warm","duration_ms":%d,"image":%s}\n' "${warm_ms}" "$(json_string "${image}")" >>"${output}"

marker="SPOREVM_NODE_READY"
for iteration in $(seq 1 "${iterations}"); do
  save_dir="${workdir}/save-${iteration}.spore"
  events_pipe="${workdir}/events-${iteration}.pipe"
  stdout_path="${workdir}/save-${iteration}.stdout"
  stderr_path="${workdir}/save-${iteration}.stderr"
  mkfifo "${events_pipe}"

  start_ms="$(now_ms)"
  spore_args=(
    --debug run --events=jsonl --backend "${backend}" --memory "${memory}"
    --image "${image}" --save "${save_dir}" --save-on USR1 --
    /bin/sh -lc "trap '' USR1; node -v >/dev/null; echo ${marker}; sleep 300"
  )
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
  printf '{"phase":"capture","iteration":%d,"duration_ms":%d,"disk_metrics":%s,"snapshot_metrics":%s,"save_dir":%s}\n' \
    "${iteration}" "${duration_ms}" "${disk_metrics}" "${snapshot_metrics}" "$(json_string "${save_dir}")" >>"${output}"
done

cat "${output}"
