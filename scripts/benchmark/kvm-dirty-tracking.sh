#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/benchmark/kvm-dirty-tracking.sh [options]

Run paired snapshot captures with the current full RAM scan path and the
backend dirty-tracking path. Each result is written as one JSON object per line.
The script name is historical; use --backend hvf for macOS write-protect runs.

Options:
  --backend kvm|hvf          hypervisor harness to benchmark (default: kvm)
  --kernel Image             aarch64 Linux kernel Image (default: managed initrd
                              kernel, or managed sporevm kernel for idle/fork)
  --initrd root.cpio         prebuilt ticker initrd (default: build one)
  --mem-mib-list "N ..."     memory sizes to test (default: "512 4096")
  --modes "MODE ..."         modes to run: full-scan plus dirty-log (KVM) or
                              write-protect (HVF); defaults by backend
  --snapshot-after-ms N      capture delay before snapshot (default: 3000)
  --dirty-epoch-ms N         dirty tracking epoch cadence; 0 means tail only (default: 250)
  --initrd-mode MODE         initrd workload: ticker, idle, fork, or dirty (default: ticker)
  --iterations N             paired repetitions per memory size (default: 1)
  --parallel-vms N           captures to run concurrently per mode/iteration (default: 1)
  --workdir DIR              work directory (default: mktemp)
  --output PATH              JSONL output path (default: <workdir>/dirty-tracking.jsonl)
  --boot-bin PATH            use an already-built backend boot harness
  --no-build                 do not run `zig build <backend>-boot`
  -h, --help                 show this help
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

backend="kvm"
kernel=""
initrd=""
mem_mib_list="512 4096"
modes=""
snapshot_after_ms="3000"
dirty_epoch_ms="250"
initrd_mode="ticker"
iterations="1"
parallel_vms="1"
workdir=""
output=""
boot_bin=""
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
    --mem-mib-list)
      need_option_value "$1" "${2-}"
      mem_mib_list="${2:-}"
      shift 2
      ;;
    --modes)
      need_option_value "$1" "${2-}"
      modes="${2:-}"
      shift 2
      ;;
    --snapshot-after-ms)
      need_option_value "$1" "${2-}"
      snapshot_after_ms="${2:-}"
      shift 2
      ;;
    --dirty-epoch-ms)
      need_option_value "$1" "${2-}"
      dirty_epoch_ms="${2:-}"
      shift 2
      ;;
    --initrd-mode)
      need_option_value "$1" "${2-}"
      initrd_mode="${2:-}"
      shift 2
      ;;
    --iterations)
      need_option_value "$1" "${2-}"
      iterations="${2:-}"
      shift 2
      ;;
    --parallel-vms)
      need_option_value "$1" "${2-}"
      parallel_vms="${2:-}"
      shift 2
      ;;
    --workdir)
      need_option_value "$1" "${2-}"
      workdir="${2:-}"
      shift 2
      ;;
    --output)
      need_option_value "$1" "${2-}"
      output="${2:-}"
      shift 2
      ;;
    --boot-bin)
      need_option_value "$1" "${2-}"
      boot_bin="${2:-}"
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
case "${initrd_mode}" in
  ticker|idle|fork|dirty) ;;
  *) die "--initrd-mode must be ticker, idle, fork, or dirty" ;;
esac
if [[ -z "${modes}" ]]; then
  case "${backend}" in
    kvm) modes="full-scan dirty-log" ;;
    hvf) modes="full-scan write-protect" ;;
  esac
fi
dirty_mode="dirty-log"
if [[ "${backend}" == "hvf" ]]; then
  dirty_mode="write-protect"
fi
for numeric_value in "${snapshot_after_ms}" "${dirty_epoch_ms}" "${iterations}" "${parallel_vms}"; do
  case "${numeric_value}" in
    ''|*[!0-9]*) die "numeric options must be decimal integers" ;;
  esac
done
[[ "${parallel_vms}" != "0" ]] || die "--parallel-vms must be greater than zero"
for mem_mib in ${mem_mib_list}; do
  case "${mem_mib}" in
    ''|*[!0-9]*) die "--mem-mib-list values must be decimal integers" ;;
  esac
done
for mode in ${modes}; do
  if [[ "${mode}" == "full-scan" ]]; then
    continue
  fi
  case "${backend}:${mode}" in
    kvm:dirty-log|hvf:write-protect) ;;
    *) die "--modes values for ${backend} must be full-scan or ${dirty_mode}" ;;
  esac
done

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-${backend}-dirty.XXXXXX")"
fi
mkdir -p "${workdir}"

if [[ -z "${output}" ]]; then
  output="${workdir}/dirty-tracking.jsonl"
fi
: >"${output}"

if [[ -z "${kernel}" ]]; then
  kernel_kind="initrd"
  case "${initrd_mode}" in
    idle|fork) kernel_kind="sporevm" ;;
  esac
  kernel="$("${repo_root}/scripts/kernel/ensure-managed-kernel.sh" "${kernel_kind}")"
  echo "using managed ${kernel_kind} kernel: ${kernel}" >&2
fi
[[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"

if [[ -z "${initrd}" ]]; then
  initrd="${workdir}/${initrd_mode}.cpio"
  "${repo_root}/scripts/kernel/make-smoke-initrd.sh" --mode "${initrd_mode}" "${initrd}"
fi
[[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"

if [[ -z "${boot_bin}" ]]; then
  boot_bin="${repo_root}/zig-out/bin/${backend}-boot"
fi

if [[ "${build}" == "1" ]]; then
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build "${backend}-boot")
  else
    (cd "${repo_root}" && zig build "${backend}-boot")
  fi
fi
[[ -x "${boot_bin}" ]] || die "boot harness not executable: ${boot_bin}"

run_with_deadline() {
  local seconds="$1"
  local log="$2"
  shift 2

  : >"${log}"
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

  if grep -q "${marker}" "${log}"; then
    return 124
  fi
  return "${status}"
}

capture_name() {
  local mode="$1"
  local mem_mib="$2"
  local iteration="$3"
  local vm_index="$4"
  if [[ "${parallel_vms}" == "1" ]]; then
    echo "${mode}-${mem_mib}-${iteration}"
  else
    printf '%s-%s-%s-vm%06d' "${mode}" "${mem_mib}" "${iteration}" "${vm_index}"
  fi
}

emit_jsonl() {
  local requested_mode="$1"
  local mem_mib="$2"
  local iteration="$3"
  local vm_index="$4"
  local log="$5"
  local line="$6"
  python3 - "${backend}" "${requested_mode}" "${mem_mib}" "${iteration}" "${parallel_vms}" "${vm_index}" "${log}" "${line}" <<'PY' >>"${output}"
import json
import re
import sys

backend, requested_mode, mem_mib, iteration, parallel_vms, vm_index, log, line = sys.argv[1:]
pairs = dict(re.findall(r'([A-Za-z0-9_]+)=([^\s]+)', line))
out = {
    "backend": backend,
    "requested_mode": requested_mode,
    "mem_mib": int(mem_mib),
    "iteration": int(iteration),
    "parallel_vms": int(parallel_vms),
    "vm_index": int(vm_index),
    "log": log,
}
for key, value in pairs.items():
    if re.fullmatch(r'[0-9]+', value):
        out[key] = int(value)
    else:
        out[key] = value
print(json.dumps(out, sort_keys=True))
PY
}

run_capture() {
  local mode="$1"
  local mem_mib="$2"
  local iteration="$3"
  local vm_index="$4"
  local name
  name="$(capture_name "${mode}" "${mem_mib}" "${iteration}" "${vm_index}")"
  local spore_dir="${workdir}/spore-${name}"
  local log="${workdir}/${name}.log"
  rm -rf "${spore_dir}"
  local cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --initrd "${initrd}" --snapshot-after-ms "${snapshot_after_ms}" --spore "${spore_dir}")
  if [[ "${mode}" != "full-scan" ]]; then
    cmd+=(--dirty-track --dirty-epoch-ms "${dirty_epoch_ms}")
  fi

  run_with_deadline "${deadline}" "${log}" "${cmd[@]}"
}

record_capture() {
  local mode="$1"
  local mem_mib="$2"
  local iteration="$3"
  local vm_index="$4"
  local name
  name="$(capture_name "${mode}" "${mem_mib}" "${iteration}" "${vm_index}")"
  local log="${workdir}/${name}.log"
  local line
  line="$(grep -E "${backend} snapshot metrics:" "${log}" | tail -1 || true)"
  [[ -n "${line}" ]] || die "missing ${backend} snapshot metrics in ${log}"
  emit_jsonl "${mode}" "${mem_mib}" "${iteration}" "${vm_index}" "${log}" "${line}"
  echo "dirty benchmark result: backend=${backend} mode=${mode} mem_mib=${mem_mib} iteration=${iteration} vm_index=${vm_index} parallel_vms=${parallel_vms} log=${log}" >&2
}

deadline=$(( (snapshot_after_ms + 999) / 1000 + 120 ))

for mem_mib in ${mem_mib_list}; do
  for ((iteration = 1; iteration <= iterations; iteration++)); do
    for mode in ${modes}; do
      pids=()
      for ((vm_index = 1; vm_index <= parallel_vms; vm_index++)); do
        run_capture "${mode}" "${mem_mib}" "${iteration}" "${vm_index}" &
        pids+=("$!")
      done

      status=0
      for pid in "${pids[@]}"; do
        if ! wait "${pid}"; then
          status=1
        fi
      done
      if [[ "${status}" != "0" ]]; then
        for ((vm_index = 1; vm_index <= parallel_vms; vm_index++)); do
          log="${workdir}/$(capture_name "${mode}" "${mem_mib}" "${iteration}" "${vm_index}").log"
          tail -80 "${log}" >&2 || true
        done
        die "${backend} ${mode} capture failed for ${mem_mib}MiB iteration ${iteration} parallel_vms=${parallel_vms}"
      fi

      for ((vm_index = 1; vm_index <= parallel_vms; vm_index++)); do
        record_capture "${mode}" "${mem_mib}" "${iteration}" "${vm_index}"
      done
    done
  done
done

echo "dirty benchmark ok: output=${output} workdir=${workdir}"
