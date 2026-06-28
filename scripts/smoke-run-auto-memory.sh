#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
backend="${SPORE_BACKEND:-}"
image="${SPORE_AUTO_MEMORY_IMAGE:-docker.io/library/node:22-alpine}"
idle_max_kb="${SPORE_AUTO_MEMORY_IDLE_MAX_KB:-1000000}"
pressure_min_kb="${SPORE_AUTO_MEMORY_PRESSURE_MIN_KB:-1500000}"

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

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-auto-memory.XXXXXX")"
export SPOREVM_ROOTFS_CACHE="${SPOREVM_ROOTFS_CACHE:-${workdir}/rootfs-cache}"
export SPOREVM_BUNDLE_CACHE="${SPOREVM_BUNDLE_CACHE:-${workdir}/bundle-cache}"
mkdir -p "${SPOREVM_ROOTFS_CACHE}" "${SPOREVM_BUNDLE_CACHE}"

cleanup() {
  local rc="$?"
  if [[ "${rc}" != "0" || -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:run-auto-memory kept workdir=${workdir}" >&2
    for log in "${workdir}"/*.log; do
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

idle_memtotal_kb="$(
  "${spore_bin}" run \
    --backend "${backend}" \
    --image "${image}" \
    --memory auto \
    --console-log "${workdir}/idle-console.log" \
    -- /bin/sh -lc "awk '/MemTotal/ {print \$2}' /proc/meminfo"
)"

[[ "${idle_memtotal_kb}" =~ ^[0-9]+$ ]] || die "idle MemTotal was not numeric: ${idle_memtotal_kb}"
if (( idle_memtotal_kb >= idle_max_kb )); then
  die "auto memory idle MemTotal ${idle_memtotal_kb} KB exceeded ${idle_max_kb} KB"
fi

node_script='b=[];for(i=0;i<32;i++)b.push(Buffer.alloc(16777216,1));setTimeout(()=>console.log(require("fs").readFileSync("/proc/meminfo","utf8").match(/MemTotal:\s+(\d+)/)[1]),3000)'

pressure_memtotal_kb="$(
  "${spore_bin}" run \
    --backend "${backend}" \
    --image "${image}" \
    --memory auto \
    --console-log "${workdir}/pressure-console.log" \
    -- /usr/local/bin/node -e "${node_script}"
)"

[[ "${pressure_memtotal_kb}" =~ ^[0-9]+$ ]] || die "pressure MemTotal was not numeric: ${pressure_memtotal_kb}"
if (( pressure_memtotal_kb <= pressure_min_kb )); then
  die "auto memory pressure MemTotal ${pressure_memtotal_kb} KB did not exceed ${pressure_min_kb} KB"
fi

echo "smoke:run-auto-memory ok backend=${backend} idle_memtotal_kb=${idle_memtotal_kb} pressure_memtotal_kb=${pressure_memtotal_kb}"
