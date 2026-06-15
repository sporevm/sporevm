#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/benchmark-kvm-dirty-tracking.sh [options]

Run paired KVM snapshot captures with the current full RAM scan path and the
dirty-log path. Each result is written as one JSON object per line.

Options:
  --kernel Image             aarch64 Linux kernel Image (default: managed initrd kernel)
  --initrd root.cpio         prebuilt ticker initrd (default: build one)
  --mem-mib-list "N ..."     memory sizes to test (default: "512 4096")
  --snapshot-after-ms N      capture delay before snapshot (default: 3000)
  --dirty-epoch-ms N         dirty-log epoch cadence; 0 means tail only (default: 250)
  --iterations N             paired repetitions per memory size (default: 1)
  --workdir DIR              work directory (default: mktemp)
  --output PATH              JSONL output path (default: <workdir>/dirty-tracking.jsonl)
  --boot-bin PATH            use an already-built kvm-boot harness
  --no-build                 do not run `zig build kvm-boot`
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kernel=""
initrd=""
mem_mib_list="512 4096"
snapshot_after_ms="3000"
dirty_epoch_ms="250"
iterations="1"
workdir=""
output=""
boot_bin=""
build=1

while (($#)); do
  case "$1" in
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
    --iterations)
      need_option_value "$1" "${2-}"
      iterations="${2:-}"
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

for numeric_value in "${snapshot_after_ms}" "${dirty_epoch_ms}" "${iterations}"; do
  case "${numeric_value}" in
    ''|*[!0-9]*) die "numeric options must be decimal integers" ;;
  esac
done
for mem_mib in ${mem_mib_list}; do
  case "${mem_mib}" in
    ''|*[!0-9]*) die "--mem-mib-list values must be decimal integers" ;;
  esac
done

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-kvm-dirty.XXXXXX")"
fi
mkdir -p "${workdir}"

if [[ -z "${output}" ]]; then
  output="${workdir}/dirty-tracking.jsonl"
fi
: >"${output}"

if [[ -z "${kernel}" ]]; then
  kernel="$("${repo_root}/scripts/ensure-managed-kernel.sh" initrd)"
  echo "using managed kernel: ${kernel}" >&2
fi
[[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"

if [[ -z "${initrd}" ]]; then
  initrd="${workdir}/ticker.cpio"
  "${repo_root}/scripts/make-smoke-initrd.sh" --mode ticker "${initrd}"
fi
[[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"

if [[ -z "${boot_bin}" ]]; then
  boot_bin="${repo_root}/zig-out/bin/kvm-boot"
fi

if [[ "${build}" == "1" ]]; then
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build kvm-boot)
  else
    (cd "${repo_root}" && zig build kvm-boot)
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

emit_jsonl() {
  local requested_mode="$1"
  local mem_mib="$2"
  local iteration="$3"
  local log="$4"
  local line="$5"
  python3 - "${requested_mode}" "${mem_mib}" "${iteration}" "${log}" "${line}" <<'PY' >>"${output}"
import json
import re
import sys

requested_mode, mem_mib, iteration, log, line = sys.argv[1:]
pairs = dict(re.findall(r'([A-Za-z0-9_]+)=([^\s]+)', line))
out = {
    "requested_mode": requested_mode,
    "mem_mib": int(mem_mib),
    "iteration": int(iteration),
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

deadline=$(( (snapshot_after_ms + 999) / 1000 + 120 ))

for mem_mib in ${mem_mib_list}; do
  for ((iteration = 1; iteration <= iterations; iteration++)); do
    for mode in full-scan dirty-log; do
      spore_dir="${workdir}/spore-${mode}-${mem_mib}-${iteration}"
      log="${workdir}/${mode}-${mem_mib}-${iteration}.log"
      rm -rf "${spore_dir}"
      cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --initrd "${initrd}" --snapshot-after-ms "${snapshot_after_ms}" --spore "${spore_dir}")
      if [[ "${mode}" == "dirty-log" ]]; then
        cmd+=(--dirty-track --dirty-epoch-ms "${dirty_epoch_ms}")
      fi

      set +e
      run_with_deadline "${deadline}" "${log}" "${cmd[@]}"
      status="$?"
      set -e
      if [[ "${status}" != "0" ]]; then
        tail -80 "${log}" >&2 || true
        die "${mode} capture failed for ${mem_mib}MiB iteration ${iteration} with status ${status}"
      fi
      line="$(grep -E 'kvm snapshot metrics:' "${log}" | tail -1 || true)"
      [[ -n "${line}" ]] || die "missing kvm snapshot metrics in ${log}"
      emit_jsonl "${mode}" "${mem_mib}" "${iteration}" "${log}" "${line}"
      echo "dirty benchmark result: mode=${mode} mem_mib=${mem_mib} iteration=${iteration} log=${log}" >&2
    done
  done
done

echo "dirty benchmark ok: output=${output} workdir=${workdir}"
