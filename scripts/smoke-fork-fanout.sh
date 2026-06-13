#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-fork-fanout.sh --backend kvm|hvf --kernel Image [options]

Boot the fork-aware smoke initrd, capture one parent spore, fork it into N
children, resume each child on the same host, and assert that each resumed guest
observes unique fork identity plus resume-time volatile parameters. Use a
SporeVM kernel asset with /dev/mem support, for example
`sporevm-arm64-linux-<version>-Image` from buildkite/cleanroom-kernels.

Options:
  --backend kvm|hvf          Hypervisor harness to run
  --kernel Image            aarch64 Linux kernel Image
  --initrd root.cpio        prebuilt fork-aware initrd (default: build one)
  --workdir DIR             work directory (default: mktemp)
  --count N                 number of children to fork/resume (default: 8)
  --parallel N              child resumes to run per batch (default: 1)
  --mem-mib N               guest memory size (default: 512)
  --snapshot-after-ms N     capture delay before snapshot (default: 3000)
  --resume-seconds N        seconds to let each child run (default: 6)
  --memory-sample-seconds N keep matched KVM children alive and sample host
                            /proc smaps_rollup after N seconds (default: 0)
  --max-host-pss-mib N      fail if sampled child PSS exceeds this MiB total
  --ram-backing-mode MODE   KVM child RAM backing handoff: path or fdpass
                            (default: path)
  --cmdline TEXT            override fresh-boot kernel command line
  --boot-bin PATH           use an already-built boot harness
  --spore-bin PATH          use an already-built spore CLI
  --no-build                do not run zig build steps
  -h, --help                show this help

Example:
  CC="zig cc -target aarch64-linux-musl" scripts/smoke-fork-fanout.sh \
    --backend kvm --kernel /tmp/sporevm-arm64-linux-6.1.155-Image --count 8
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_option_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backend=""
kernel=""
initrd=""
workdir=""
count="8"
parallel="1"
mem_mib="512"
snapshot_after_ms="3000"
resume_seconds="6"
memory_sample_seconds="0"
max_host_pss_mib=""
ram_backing_mode="path"
cmdline=""
boot_bin=""
spore_bin=""
build=1

while (($#)); do
  case "$1" in
    --backend)
      need_option_value "$1" "${2-}"
      backend="${2:-}"
      shift 2
      ;;
    --kernel)
      need_option_value "$1" "${2-}"
      kernel="${2:-}"
      shift 2
      ;;
    --initrd)
      need_option_value "$1" "${2-}"
      initrd="${2:-}"
      shift 2
      ;;
    --workdir)
      need_option_value "$1" "${2-}"
      workdir="${2:-}"
      shift 2
      ;;
    --count)
      need_option_value "$1" "${2-}"
      count="${2:-}"
      shift 2
      ;;
    --parallel)
      need_option_value "$1" "${2-}"
      parallel="${2:-}"
      shift 2
      ;;
    --mem-mib)
      need_option_value "$1" "${2-}"
      mem_mib="${2:-}"
      shift 2
      ;;
    --snapshot-after-ms)
      need_option_value "$1" "${2-}"
      snapshot_after_ms="${2:-}"
      shift 2
      ;;
    --resume-seconds)
      need_option_value "$1" "${2-}"
      resume_seconds="${2:-}"
      shift 2
      ;;
    --memory-sample-seconds)
      need_option_value "$1" "${2-}"
      memory_sample_seconds="${2:-}"
      shift 2
      ;;
    --max-host-pss-mib)
      need_option_value "$1" "${2-}"
      max_host_pss_mib="${2:-}"
      shift 2
      ;;
    --ram-backing-mode)
      need_option_value "$1" "${2-}"
      ram_backing_mode="${2:-}"
      shift 2
      ;;
    --cmdline)
      need_option_value "$1" "${2-}"
      cmdline="${2:-}"
      shift 2
      ;;
    --boot-bin)
      need_option_value "$1" "${2-}"
      boot_bin="${2:-}"
      shift 2
      ;;
    --spore-bin)
      need_option_value "$1" "${2-}"
      spore_bin="${2:-}"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "${backend}" in
  kvm|hvf) ;;
  *) die "--backend must be kvm or hvf" ;;
esac
case "${ram_backing_mode}" in
  path|fdpass) ;;
  *) die "--ram-backing-mode must be path or fdpass" ;;
esac
if [[ "${ram_backing_mode}" == "fdpass" && "${backend}" != "kvm" ]]; then
  die "--ram-backing-mode fdpass currently requires --backend kvm"
fi

[[ -n "${kernel}" ]] || die "--kernel is required"
[[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"

for numeric_value in "${count}" "${parallel}" "${mem_mib}" "${snapshot_after_ms}" "${resume_seconds}" "${memory_sample_seconds}"; do
  case "${numeric_value}" in
    ''|*[!0-9]*) die "numeric options must be decimal integers" ;;
  esac
done
if [[ -n "${max_host_pss_mib}" ]]; then
  case "${max_host_pss_mib}" in
    ''|*[!0-9]*) die "--max-host-pss-mib must be a decimal integer" ;;
  esac
fi
(( count > 0 )) || die "--count must be greater than zero"
(( parallel > 0 )) || die "--parallel must be greater than zero"
if (( memory_sample_seconds > 0 )) && [[ "${backend}" != "kvm" ]]; then
  die "--memory-sample-seconds currently requires --backend kvm"
fi
if [[ -n "${max_host_pss_mib}" && "${memory_sample_seconds}" == "0" ]]; then
  die "--max-host-pss-mib requires --memory-sample-seconds"
fi

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-fork-smoke.XXXXXX")"
fi
mkdir -p "${workdir}"

if [[ -z "${boot_bin}" ]]; then
  boot_bin="${repo_root}/zig-out/bin/${backend}-boot"
fi
if [[ -z "${spore_bin}" ]]; then
  spore_bin="${repo_root}/zig-out/bin/spore"
fi
if [[ -z "${initrd}" ]]; then
  initrd="${workdir}/fork-smoke.cpio"
fi
metrics_json="${workdir}/metrics.json"

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.monotonic_ns() // 1_000_000)'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

build_all() {
  if [[ "${build}" == "0" ]]; then
    return
  fi
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build)
    (cd "${repo_root}" && mise exec -- zig build "${backend}-boot")
  else
    (cd "${repo_root}" && zig build)
    (cd "${repo_root}" && zig build "${backend}-boot")
  fi
}

safe_remove() {
  local path="$1"
  [[ -n "${path}" ]] || die "empty path"
  [[ "${path}" != "/" ]] || die "refusing to remove /"
  rm -rf "${path}"
}

print_tail() {
  local log="$1"
  echo "--- ${log} tail ---" >&2
  tail -120 "${log}" >&2 || true
  echo "--- end tail ---" >&2
}

RUN_DURATION_MS=0
RUN_PID=""
RUN_PID_FILE=""
keep_matched_process=0
if (( memory_sample_seconds > 0 )); then
  keep_matched_process=1
fi

run_with_deadline() {
  local seconds="$1"
  local log="$2"
  shift 2

  : >"${log}"
  local start_ms
  start_ms="$(now_ms)"
  "$@" >"${log}" 2>&1 &
  local pid="$!"
  local marker="__sporevm_deadline_${pid}__"

  (
    sleep "${seconds}"
    if kill -0 "${pid}" >/dev/null 2>&1; then
      printf '\n%s\n' "${marker}" >>"${log}"
      kill -TERM "${pid}" >/dev/null 2>&1 || true
      sleep 2
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  ) &
  local timer="$!"

  wait "${pid}"
  local status="$?"

  kill "${timer}" >/dev/null 2>&1 || true
  wait "${timer}" >/dev/null 2>&1 || true

  RUN_DURATION_MS=$(( $(now_ms) - start_ms ))

  if grep -q "${marker}" "${log}"; then
    return 124
  fi
  return "${status}"
}

run_until_log_matches() {
  local seconds="$1"
  local pattern="$2"
  local log="$3"
  shift 3

  : >"${log}"
  RUN_PID=""
  local start_ms
  start_ms="$(now_ms)"
  local deadline_ms=$(( start_ms + seconds * 1000 ))
  local pid
  "$@" >"${log}" 2>&1 &
  pid="$!"
  RUN_PID="${pid}"
  if [[ -n "${RUN_PID_FILE}" ]]; then
    echo "${pid}" >"${RUN_PID_FILE}"
  fi
  local marker="__sporevm_deadline_${pid}__"
  local status=124

  while true; do
    if grep -qE "${pattern}" "${log}"; then
      status=0
      break
    fi
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      wait "${pid}"
      status="$?"
      if grep -qE "${pattern}" "${log}"; then
        status=0
      fi
      break
    fi
    if (( $(now_ms) >= deadline_ms )); then
      printf '\n%s\n' "${marker}" >>"${log}"
      status=124
      break
    fi
    sleep 0.1
  done

  if (( keep_matched_process == 1 && status == 0 )) && kill -0 "${pid}" >/dev/null 2>&1; then
    RUN_DURATION_MS=$(( $(now_ms) - start_ms ))
    return 0
  fi

  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    sleep 0.2
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi

  RUN_DURATION_MS=$(( $(now_ms) - start_ms ))
  return "${status}"
}

field_value() {
  local key="$1"
  local log="$2"
  grep -Eao "${key}=[^[:space:]]+" "${log}" | head -1 | cut -d= -f2-
}

assert_log_contains() {
  local pattern="$1"
  local log="$2"
  if ! grep -qE "${pattern}" "${log}"; then
    print_tail "${log}"
    die "${log} did not match ${pattern}"
  fi
}

json_string() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
  else
    printf '"%s"' "$1"
  fi
}

write_metrics() {
  local children_wall_ms="$1"
  local child_resume_sum_ms="$2"
  local child_resume_min_ms="$3"
  local child_resume_max_ms="$4"
  local file_backed_children="$5"
  local total_ms="$6"

  {
    echo "{"
    echo "  \"backend\": $(json_string "${backend}"),"
    echo "  \"count\": ${count},"
    echo "  \"parallel\": ${parallel},"
    echo "  \"mem_mib\": ${mem_mib},"
    echo "  \"ram_backing_mode\": $(json_string "${ram_backing_mode}"),"
    echo "  \"snapshot_after_ms\": ${snapshot_after_ms},"
    echo "  \"resume_deadline_seconds\": ${resume_seconds},"
    echo "  \"workdir\": $(json_string "${workdir}"),"
    echo "  \"capture_ms\": ${capture_ms},"
    echo "  \"fork_ms\": ${fork_ms},"
    echo "  \"children_resume_wall_ms\": ${children_wall_ms},"
    echo "  \"children_resume_sum_ms\": ${child_resume_sum_ms},"
    echo "  \"child_resume_min_ms\": ${child_resume_min_ms},"
    echo "  \"child_resume_max_ms\": ${child_resume_max_ms},"
    echo "  \"file_backed_children\": ${file_backed_children},"
    echo "  \"host_memory_sample_seconds\": ${memory_sample_seconds},"
    echo "  \"host_memory_sampled_children\": ${host_memory_sampled_children},"
    echo "  \"host_rss_kib\": ${host_rss_kib},"
    echo "  \"host_pss_kib\": ${host_pss_kib},"
    echo "  \"host_private_kib\": ${host_private_kib},"
    echo "  \"total_smoke_ms\": ${total_ms},"
    echo "  \"children\": ["
    for ((i = 0; i < count; i++)); do
      local comma=","
      if (( i == count - 1 )); then
        comma=""
      fi
      echo "    {\"index\": ${i}, \"resume_ms\": ${child_resume_ms[i]}, \"log\": $(json_string "${child_logs[i]}")}${comma}"
    done
    echo "  ]"
    echo "}"
  } >"${metrics_json}"
}

build_all

[[ -x "${boot_bin}" ]] || die "boot harness not executable: ${boot_bin}"
[[ -x "${spore_bin}" ]] || die "spore CLI not executable: ${spore_bin}"

if [[ ! -f "${initrd}" ]]; then
  "${repo_root}/scripts/make-smoke-initrd.sh" --mode fork "${initrd}"
fi
[[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"

parent_spore="${workdir}/parent-spore"
children_dir="${workdir}/children"
safe_remove "${parent_spore}"
safe_remove "${children_dir}"
smoke_start_ms="$(now_ms)"

capture_log="${workdir}/capture.log"
capture_deadline=$(( (snapshot_after_ms + 999) / 1000 + 30 ))
capture_cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --initrd "${initrd}" --snapshot-after-ms "${snapshot_after_ms}" --spore "${parent_spore}")
if [[ -n "${cmdline}" ]]; then
  capture_cmd+=(--cmdline "${cmdline}")
fi

set +e
run_with_deadline "${capture_deadline}" "${capture_log}" "${capture_cmd[@]}"
capture_status="$?"
set -e
capture_ms="${RUN_DURATION_MS}"
if [[ "${capture_status}" != "0" ]]; then
  print_tail "${capture_log}"
  die "capture failed with status ${capture_status}"
fi
[[ -f "${parent_spore}/manifest.json" ]] || die "capture did not write ${parent_spore}/manifest.json"

fork_start_ms="$(now_ms)"
"${spore_bin}" fork "${parent_spore}" --count "${count}" --out "${children_dir}" >"${workdir}/fork.json"
fork_ms=$(( $(now_ms) - fork_start_ms ))

vm_ids=()
hostnames=()
mac_addresses=()
entropy_seeds=()
resume_times=()
child_resume_ms=()
child_logs=()
child_file_backed=()
result_dir="${workdir}/child-results"
safe_remove "${result_dir}"
mkdir -p "${result_dir}"

run_child_resume() {
  local i="$1"
  local child_dir="${children_dir}/$(printf '%06d' "${i}")"
  [[ -f "${child_dir}/manifest.json" ]] || die "missing child manifest: ${child_dir}/manifest.json"
  local log="${workdir}/child-$(printf '%06d' "${i}").log"
  local result="${result_dir}/$(printf '%06d' "${i}").result"
  local complete_pattern="sporevm-fork-smoke acked_generation=.*irq_status_after_ack=0"
  local cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --resume "${child_dir}")
  if [[ "${backend}" == "kvm" ]]; then
    cmd+=(--trust-ram-backing)
    if [[ "${ram_backing_mode}" == "fdpass" ]]; then
      cmd+=(--fdpass-ram-backing)
    fi
  fi

  set +e
  RUN_PID_FILE="${result}.pid"
  run_until_log_matches "${resume_seconds}" "${complete_pattern}" "${log}" "${cmd[@]}"
  local status="$?"
  local duration_ms="${RUN_DURATION_MS}"
  RUN_PID_FILE=""
  set -e

  {
    echo "status=${status}"
    echo "resume_ms=${duration_ms}"
    echo "log=${log}"
    echo "pid=${RUN_PID}"
  } >"${result}"
}

child_pids=()

cleanup_child_pids() {
  if (( memory_sample_seconds == 0 )); then
    return
  fi
  local pids=("${child_pids[@]}")
  local pid_file result pid
  if [[ -d "${result_dir:-}" ]]; then
    for pid_file in "${result_dir}"/*.pid; do
      [[ -f "${pid_file}" ]] || continue
      pid="$(cat "${pid_file}")"
      [[ -n "${pid}" ]] && pids+=("${pid}")
    done
    for result in "${result_dir}"/*.result; do
      [[ -f "${result}" ]] || continue
      pid="$(awk -F= '$1 == "pid" { print $2 }' "${result}")"
      [[ -n "${pid}" ]] && pids+=("${pid}")
    done
  fi

  for pid in "${pids[@]}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill -TERM "${pid}" >/dev/null 2>&1 || true
    fi
  done
  sleep 0.2
  for pid in "${pids[@]}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup_child_pids EXIT

host_memory_sampled_children=0
host_rss_kib=0
host_pss_kib=0
host_private_kib=0

sample_host_memory() {
  if (( memory_sample_seconds == 0 )); then
    return
  fi

  sleep "${memory_sample_seconds}"
  local pid rss_kib pss_kib private_kib
  for pid in "${child_pids[@]}"; do
    [[ -r "/proc/${pid}/smaps_rollup" ]] || continue
    read -r rss_kib pss_kib private_kib < <(
      awk '
        /^Rss:/ { rss = $2 }
        /^Pss:/ { pss = $2 }
        /^Private_Clean:/ { private += $2 }
        /^Private_Dirty:/ { private += $2 }
        END { printf "%d %d %d\n", rss, pss, private }
      ' "/proc/${pid}/smaps_rollup"
    )
    host_rss_kib=$(( host_rss_kib + rss_kib ))
    host_pss_kib=$(( host_pss_kib + pss_kib ))
    host_private_kib=$(( host_private_kib + private_kib ))
    host_memory_sampled_children=$(( host_memory_sampled_children + 1 ))
  done

  if [[ "${host_memory_sampled_children}" != "${count}" ]]; then
    die "sampled host memory for ${host_memory_sampled_children}/${count} children"
  fi

  if [[ -n "${max_host_pss_mib}" ]]; then
    local max_host_pss_kib=$(( max_host_pss_mib * 1024 ))
    if (( host_pss_kib > max_host_pss_kib )); then
      die "host child PSS ${host_pss_kib}KiB exceeds limit ${max_host_pss_kib}KiB"
    fi
  fi
}

wait_batch() {
  for pid in "${batch_pids[@]}"; do
    wait "${pid}"
  done
  batch_pids=()
}

children_start_ms="$(now_ms)"
batch_pids=()
for ((i = 0; i < count; i++)); do
  run_child_resume "${i}" &
  batch_pids+=("$!")
  if (( ${#batch_pids[@]} >= parallel )); then
    wait_batch
  fi
done
if (( ${#batch_pids[@]} > 0 )); then
  wait_batch
fi
children_resume_wall_ms=$(( $(now_ms) - children_start_ms ))

for ((i = 0; i < count; i++)); do
  result="${result_dir}/$(printf '%06d' "${i}").result"
  [[ -f "${result}" ]] || die "missing child result: ${result}"
  status="$(awk -F= '$1 == "status" { print $2 }' "${result}")"
  resume_ms="$(awk -F= '$1 == "resume_ms" { print $2 }' "${result}")"
  log="$(awk -F= '$1 == "log" { print substr($0, index($0, "=") + 1) }' "${result}")"
  pid="$(awk -F= '$1 == "pid" { print $2 }' "${result}")"
  if (( memory_sample_seconds > 0 )); then
    child_pids[i]="${pid}"
  fi
  if [[ "${status}" != "0" ]]; then
    print_tail "${log}"
    die "child ${i} did not finish fork fixup before deadline; status ${status}"
  fi

  assert_log_contains "sporevm-fork-smoke generation=.*fork_index=${i}.*fork_count=${count}.*irq_status=1" "${log}"
  assert_log_contains "sporevm-fork-smoke vm_id=spore-[0-9a-f]+ hostname=spore-[0-9a-f]+-[0-9]{6} mac_address=([0-9a-f]{2}:){5}[0-9a-f]{2}" "${log}"
  assert_log_contains "resume_time_unix_ns=[1-9][0-9]*" "${log}"
  assert_log_contains "entropy_seed=[0-9a-f]{32}" "${log}"
  assert_log_contains "irq_status_after_ack=0" "${log}"
  if [[ "${ram_backing_mode}" == "fdpass" ]]; then
    assert_log_contains "received RAM backing fd via SCM_RIGHTS harness path" "${log}"
  fi

  vm_ids+=("$(field_value vm_id "${log}")")
  hostnames+=("$(field_value hostname "${log}")")
  mac_addresses+=("$(field_value mac_address "${log}")")
  entropy_seeds+=("$(field_value entropy_seed "${log}")")
  resume_times+=("$(field_value resume_time_unix_ns "${log}")")
  child_resume_ms[i]="${resume_ms}"
  child_logs[i]="${log}"
  if grep -q "mapped RAM from file backing" "${log}"; then
    child_file_backed[i]=1
  else
    child_file_backed[i]=0
  fi
  echo "child ok: index=${i} vm_id=${vm_ids[-1]} hostname=${hostnames[-1]} resume_ms=${resume_ms} log=${log}"
done

unique_count() {
  printf '%s\n' "$@" | LC_ALL=C sort -u | wc -l | tr -d ' '
}

[[ "$(unique_count "${vm_ids[@]}")" == "${count}" ]] || die "vm_id values were not unique"
[[ "$(unique_count "${hostnames[@]}")" == "${count}" ]] || die "hostname values were not unique"
[[ "$(unique_count "${mac_addresses[@]}")" == "${count}" ]] || die "mac_address values were not unique"
[[ "$(unique_count "${entropy_seeds[@]}")" == "${count}" ]] || die "entropy_seed values were not unique"

sample_host_memory

child_resume_sum_ms=0
child_resume_min_ms="${child_resume_ms[0]}"
child_resume_max_ms="${child_resume_ms[0]}"
file_backed_children=0
for ((i = 0; i < count; i++)); do
  child_resume_sum_ms=$(( child_resume_sum_ms + child_resume_ms[i] ))
  file_backed_children=$(( file_backed_children + child_file_backed[i] ))
  if (( child_resume_ms[i] < child_resume_min_ms )); then
    child_resume_min_ms="${child_resume_ms[i]}"
  fi
  if (( child_resume_ms[i] > child_resume_max_ms )); then
    child_resume_max_ms="${child_resume_ms[i]}"
  fi
done
if [[ "${backend}" == "kvm" && "${file_backed_children}" != "${count}" ]]; then
  die "expected every KVM child to use file-backed RAM; got ${file_backed_children}/${count}"
fi
total_smoke_ms=$(( $(now_ms) - smoke_start_ms ))
write_metrics "${children_resume_wall_ms}" "${child_resume_sum_ms}" "${child_resume_min_ms}" "${child_resume_max_ms}" "${file_backed_children}" "${total_smoke_ms}"

echo "fork fan-out metrics: capture_ms=${capture_ms} fork_ms=${fork_ms} children_resume_wall_ms=${children_resume_wall_ms} child_resume_min_ms=${child_resume_min_ms} child_resume_max_ms=${child_resume_max_ms} file_backed_children=${file_backed_children} host_memory_sampled_children=${host_memory_sampled_children} host_pss_kib=${host_pss_kib} host_rss_kib=${host_rss_kib} total_smoke_ms=${total_smoke_ms} metrics=${metrics_json}"
echo "fork fan-out ok: backend=${backend} count=${count} parallel=${parallel} workdir=${workdir}"
