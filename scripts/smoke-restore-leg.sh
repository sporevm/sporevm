#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-restore-leg.sh capture --backend kvm|hvf --kernel Image --initrd root.cpio --spore-dir DIR [options]
  scripts/smoke-restore-leg.sh resume --backend kvm|hvf --kernel Image --spore-dir DIR [options]
  scripts/smoke-restore-leg.sh same-host --backend kvm|hvf --kernel Image --initrd root.cpio [--workdir DIR] [options]

Run one restore-smoke leg using the tiny ticker initrd. Cross-host matrix runs
are intentionally split: capture on the source host, transfer the spore
directory by your chosen direct channel, then resume on the destination host.

Options:
  --backend kvm|hvf          Hypervisor harness to run
  --kernel Image            aarch64 Linux kernel Image
  --initrd root.cpio        initrd for capture/same-host fresh boot
  --spore-dir DIR           spore directory to write/read
  --workdir DIR             same-host work directory (default: mktemp)
  --mem-mib N               guest memory size (default: 512)
  --snapshot-after-ms N     capture delay before snapshot (default: 3000)
  --resume-seconds N        seconds to let resumed VM tick (default: 5)
  --min-tick N              minimum observed ticker value on resume (default: 1)
  --kvm-lazy-ram            use kvm-boot --lazy-ram for KVM resume
  --cmdline TEXT            override fresh-boot kernel command line
  --boot-bin PATH           use an already-built boot harness
  --no-build                do not run `zig build <backend>-boot`
  -h, --help                show this help

Examples:
  scripts/make-smoke-initrd.sh /tmp/sporevm-smoke.cpio
  scripts/smoke-restore-leg.sh same-host --backend kvm --kernel /tmp/Image --initrd /tmp/sporevm-smoke.cpio

  scripts/smoke-restore-leg.sh capture --backend kvm --kernel /tmp/Image --initrd /tmp/sporevm-smoke.cpio --spore-dir /tmp/kvm-spore
  tar -C /tmp -czf /tmp/kvm-spore.tgz kvm-spore
  # transfer kvm-spore.tgz directly to the HVF host, then:
  scripts/smoke-restore-leg.sh resume --backend hvf --kernel /tmp/Image --spore-dir /tmp/kvm-spore
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

mode="${1:-}"
if [[ -z "${mode}" || "${mode}" == "-h" || "${mode}" == "--help" ]]; then
  usage
  [[ -z "${mode}" ]] && exit 2 || exit 0
fi
shift

backend=""
kernel=""
initrd=""
spore_dir=""
workdir=""
mem_mib="512"
snapshot_after_ms="3000"
resume_seconds="5"
min_tick="1"
kvm_lazy_ram=0
cmdline=""
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
    --spore-dir)
      need_option_value "$1" "${2-}"
      spore_dir="${2:-}"
      shift 2
      ;;
    --workdir)
      need_option_value "$1" "${2-}"
      workdir="${2:-}"
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
    --min-tick)
      need_option_value "$1" "${2-}"
      min_tick="${2:-}"
      shift 2
      ;;
    --kvm-lazy-ram)
      kvm_lazy_ram=1
      shift
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

case "${mode}" in
  capture|resume|same-host) ;;
  *) die "unknown mode: ${mode}" ;;
esac

case "${backend}" in
  kvm|hvf) ;;
  *) die "--backend must be kvm or hvf" ;;
esac

[[ -n "${kernel}" ]] || die "--kernel is required"
[[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"

for numeric_value in "${mem_mib}" "${snapshot_after_ms}" "${resume_seconds}" "${min_tick}"; do
  case "${numeric_value}" in
    ''|*[!0-9]*) die "numeric options must be decimal integers" ;;
  esac
done

if [[ -z "${boot_bin}" ]]; then
  boot_bin="${repo_root}/zig-out/bin/${backend}-boot"
fi

build_backend() {
  if [[ "${build}" == "0" ]]; then
    return
  fi
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build "${backend}-boot")
  else
    (cd "${repo_root}" && zig build "${backend}-boot")
  fi
}

ensure_boot_bin() {
  build_backend
  [[ -x "${boot_bin}" ]] || die "boot harness not executable: ${boot_bin}"
}

safe_remove_spore_dir() {
  local dir="$1"
  [[ -n "${dir}" ]] || die "empty spore directory"
  [[ "${dir}" != "/" ]] || die "refusing to remove /"
  rm -rf "${dir}"
}

print_tail() {
  local log="$1"
  echo "--- ${log} tail ---" >&2
  tail -80 "${log}" >&2 || true
  echo "--- end tail ---" >&2
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.monotonic_ns() // 1_000_000)'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

metric_value() {
  local name="$1"
  local line="$2"
  sed -nE "s/.*(^| )${name}=([0-9]+)( |$).*/\2/p" <<<"${line}"
}

assert_kvm_restore_metrics() {
  local line="$1"
  local expected_mode="$2"
  [[ "${line}" =~ (^|[[:space:]])mode=${expected_mode}([[:space:]]|$) ]] || die "unexpected KVM restore mode in metrics: ${line}"
  for field in chunks memory_ms state_ms pre_run_ms; do
    local value
    value="$(metric_value "${field}" "${line}")"
    [[ -n "${value}" ]] || die "KVM restore metrics missing numeric ${field}: ${line}"
    if [[ "${field}" == "chunks" && "${value}" == "0" ]]; then
      die "KVM restore metrics reported zero chunks: ${line}"
    fi
  done
}

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

capture() {
  [[ -n "${initrd}" ]] || die "--initrd is required for capture"
  [[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"
  [[ -n "${spore_dir}" ]] || die "--spore-dir is required for capture"

  ensure_boot_bin
  mkdir -p "$(dirname "${spore_dir}")"
  safe_remove_spore_dir "${spore_dir}"

  local log="${spore_dir%/}.capture.log"
  local deadline=$(( (snapshot_after_ms + 999) / 1000 + 30 ))
  local cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --initrd "${initrd}" --snapshot-after-ms "${snapshot_after_ms}" --spore "${spore_dir}")
  if [[ -n "${cmdline}" ]]; then
    cmd+=(--cmdline "${cmdline}")
  fi

  set +e
  run_with_deadline "${deadline}" "${log}" "${cmd[@]}"
  local status="$?"
  set -e
  if [[ "${status}" != "0" ]]; then
    print_tail "${log}"
    die "capture failed with status ${status}"
  fi
  [[ -f "${spore_dir}/manifest.json" ]] || die "capture did not write ${spore_dir}/manifest.json"
  echo "capture ok: spore=${spore_dir} log=${log}"
}

resume() {
  [[ -n "${spore_dir}" ]] || die "--spore-dir is required for resume"
  [[ -f "${spore_dir}/manifest.json" ]] || die "spore manifest not found: ${spore_dir}/manifest.json"

  ensure_boot_bin

  local log="${spore_dir%/}.resume.${backend}.log"
  local cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --resume "${spore_dir}")
  if [[ "${backend}" == "kvm" && "${kvm_lazy_ram}" == "1" ]]; then
    cmd+=(--lazy-ram)
  fi

  set +e
  local resume_start_ms
  resume_start_ms="$(now_ms)"
  run_with_deadline "${resume_seconds}" "${log}" "${cmd[@]}"
  local status="$?"
  local resume_wall_ms=$(( $(now_ms) - resume_start_ms ))
  set -e
  if [[ "${status}" != "0" && "${status}" != "124" ]]; then
    print_tail "${log}"
    die "resume failed with status ${status}"
  fi

  local restore_metrics=""
  if [[ "${backend}" == "kvm" ]]; then
    restore_metrics="$(grep -E 'kvm restore metrics:' "${log}" | tail -1 || true)"
    if [[ -z "${restore_metrics}" ]]; then
      print_tail "${log}"
      die "resume log did not contain kvm restore metrics"
    fi
    local expected_mode="eager_chunks"
    if [[ "${kvm_lazy_ram}" == "1" ]]; then
      expected_mode="lazy_chunks"
    fi
    assert_kvm_restore_metrics "${restore_metrics}" "${expected_mode}"
  fi

  local max_tick
  max_tick="$(grep -Eao 'sporevm-initrd-tick [0-9]+' "${log}" | awk '{print $2}' | sort -n | tail -1 || true)"
  if [[ -z "${max_tick}" ]]; then
    print_tail "${log}"
    die "resume log did not contain sporevm-initrd-tick"
  fi
  if (( max_tick < min_tick )); then
    print_tail "${log}"
    die "highest observed tick ${max_tick} was below --min-tick ${min_tick}"
  fi
  echo "resume ok: backend=${backend} max_tick=${max_tick} resume_process_wall_ms=${resume_wall_ms} log=${log}"
  if [[ -n "${restore_metrics}" ]]; then
    echo "restore metrics: ${restore_metrics}"
  fi
}

case "${mode}" in
  capture)
    capture
    ;;
  resume)
    resume
    ;;
  same-host)
    [[ -n "${initrd}" ]] || die "--initrd is required for same-host"
    [[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"
    if [[ -z "${workdir}" ]]; then
      workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-restore-smoke.XXXXXX")"
    fi
    mkdir -p "${workdir}"
    spore_dir="${spore_dir:-${workdir}/spore}"
    capture
    resume
    echo "same-host ok: backend=${backend} workdir=${workdir}"
    ;;
esac
