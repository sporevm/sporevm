#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
backend="${SPORE_BACKEND:-}"
image="${SPORE_AUTO_MEMORY_IMAGE:-docker.io/library/node:22-alpine}"
idle_max_kb="${SPORE_AUTO_MEMORY_IDLE_MAX_KB:-1000000}"
pressure_min_kb="${SPORE_AUTO_MEMORY_PRESSURE_MIN_KB:-1500000}"
idle_sample_seconds="${SPORE_AUTO_MEMORY_IDLE_SAMPLE_SECONDS:-1}"

if [[ -z "${backend}" ]]; then
  case "$(uname -s)" in
    Linux) backend="kvm" ;;
    Darwin) backend="hvf" ;;
    *)
      echo "smoke:run-auto-memory skipped: unsupported host $(uname -s)"
      exit 0
      ;;
  esac
fi

[[ -x "${spore_bin}" ]] || die "spore binary not found: ${spore_bin}"
[[ "${idle_max_kb}" =~ ^[0-9]+$ ]] || die "SPORE_AUTO_MEMORY_IDLE_MAX_KB must be numeric"
[[ "${pressure_min_kb}" =~ ^[0-9]+$ ]] || die "SPORE_AUTO_MEMORY_PRESSURE_MIN_KB must be numeric"
[[ "${idle_sample_seconds}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SPORE_AUTO_MEMORY_IDLE_SAMPLE_SECONDS must be numeric"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-auto-memory.XXXXXX")"
export SPOREVM_ROOTFS_CACHE_DIR="${SPOREVM_ROOTFS_CACHE_DIR:-${workdir}/rootfs-cache}"
export SPOREVM_BUNDLE_CACHE_DIR="${SPOREVM_BUNDLE_CACHE_DIR:-${workdir}/bundle-cache}"
mkdir -p "${SPOREVM_ROOTFS_CACHE_DIR}" "${SPOREVM_BUNDLE_CACHE_DIR}"

cleanup() {
  local rc="$?"
  if [[ "${rc}" != "0" || -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:run-auto-memory kept workdir=${workdir}" >&2
    for log in "${workdir}"/*.log "${workdir}"/*.stdout "${workdir}"/*.stderr; do
      [[ -e "${log}" ]] || continue
      echo "==> ${log}" >&2
      tail -120 "${log}" >&2 || true
    done
  else
    rm -rf "${workdir}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

process_rss_kb() {
  local pid="$1"
  case "$(uname -s)" in
    Linux)
      awk '/VmRSS:/ { print $2; found=1; exit } END { if (!found) exit 1 }' "/proc/${pid}/status" 2>/dev/null
      ;;
    Darwin)
      ps -o rss= -p "${pid}" 2>/dev/null | awk 'NF { print $1; found=1; exit } END { if (!found) exit 1 }'
      ;;
    *)
      return 1
      ;;
  esac
}

RUN_CAPTURE_STDOUT=""
RUN_CAPTURE_HOST_PEAK_RSS_KB=""

run_spore_capture() {
  local label="$1"
  shift

  local stdout_log="${workdir}/${label}.stdout"
  local stderr_log="${workdir}/${label}.stderr"
  local peak_rss_kb=""
  local sample=""
  local pid=""
  local rc=""

  : > "${stdout_log}"
  : > "${stderr_log}"

  "$@" >"${stdout_log}" 2>"${stderr_log}" &
  pid="$!"

  while kill -0 "${pid}" 2>/dev/null; do
    sample="$(process_rss_kb "${pid}" || true)"
    if [[ "${sample}" =~ ^[0-9]+$ && ( -z "${peak_rss_kb}" || "${sample}" -gt "${peak_rss_kb}" ) ]]; then
      peak_rss_kb="${sample}"
    fi
    sleep 0.1
  done

  set +e
  wait "${pid}"
  rc="$?"
  set -e
  [[ "${rc}" == "0" ]] || return "${rc}"

  RUN_CAPTURE_STDOUT="$(tr -d '\r' < "${stdout_log}")"
  RUN_CAPTURE_HOST_PEAK_RSS_KB="${peak_rss_kb}"
}

run_spore_capture idle \
  "${spore_bin}" run \
    --backend "${backend}" \
    --image "${image}" \
    --memory auto \
    --console-log "${workdir}/idle-console.log" \
    -- /bin/sh -lc "awk '/MemTotal/ {print \$2}' /proc/meminfo; sleep ${idle_sample_seconds}"
idle_memtotal_kb="${RUN_CAPTURE_STDOUT}"
idle_host_peak_rss_kb="${RUN_CAPTURE_HOST_PEAK_RSS_KB}"

[[ "${idle_memtotal_kb}" =~ ^[0-9]+$ ]] || die "idle MemTotal was not numeric: ${idle_memtotal_kb}"
if (( idle_memtotal_kb >= idle_max_kb )); then
  die "auto memory idle MemTotal ${idle_memtotal_kb} KB exceeded ${idle_max_kb} KB"
fi

node_script='b=[];for(i=0;i<20;i++)b.push(Buffer.alloc(16777216,1));setTimeout(()=>console.log(require("fs").readFileSync("/proc/meminfo","utf8").match(/MemTotal:\s+(\d+)/)[1]),5000)'

run_spore_capture pressure \
  "${spore_bin}" run \
    --backend "${backend}" \
    --image "${image}" \
    --memory auto \
    --console-log "${workdir}/pressure-console.log" \
    -- /usr/local/bin/node -e "${node_script}"
pressure_memtotal_kb="${RUN_CAPTURE_STDOUT}"
pressure_host_peak_rss_kb="${RUN_CAPTURE_HOST_PEAK_RSS_KB}"

[[ "${pressure_memtotal_kb}" =~ ^[0-9]+$ ]] || die "pressure MemTotal was not numeric: ${pressure_memtotal_kb}"
if (( pressure_memtotal_kb <= pressure_min_kb )); then
  die "auto memory pressure MemTotal ${pressure_memtotal_kb} KB did not exceed ${pressure_min_kb} KB"
fi

summary="smoke:run-auto-memory ok backend=${backend} idle_memtotal_kb=${idle_memtotal_kb} pressure_memtotal_kb=${pressure_memtotal_kb}"
if [[ -n "${idle_host_peak_rss_kb}" ]]; then
  summary+=" idle_host_peak_rss_kb=${idle_host_peak_rss_kb}"
fi
if [[ -n "${pressure_host_peak_rss_kb}" ]]; then
  summary+=" pressure_host_peak_rss_kb=${pressure_host_peak_rss_kb}"
fi
echo "${summary}"
