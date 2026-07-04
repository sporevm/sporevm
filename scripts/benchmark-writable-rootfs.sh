#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Benchmark writable rootfs disk modes.

Usage:
  scripts/benchmark-writable-rootfs.sh [options]

Options:
  --backend hvf|kvm|auto        Hypervisor backend (default: auto)
  --sqlite-image REF            OCI image with python3/sqlite3 module
                                (default: docker.io/library/python:3.12-alpine)
  --package-image REF           OCI image with POSIX shell utilities
                                (default: docker.io/library/alpine:3.20)
  --platform PLATFORM           OCI platform (default: linux/arm64)
  --workload NAME               sqlite, package, or all (default: all)
  -n, --iterations N            Iterations per workload (default: 3)
  --memory-mib N                Guest memory in MiB (default: 1024)
  --timeout DURATION           Per-run timeout (default: 3m)
  --output PATH                 JSONL output path
  --spore-bin PATH              Spore binary path (default: zig-out/bin/spore)
  --raw-rootfs PATH             Optional read-only raw virtio-blk baseline rootfs
  --no-build                    Do not run mise run build first
  -h, --help                    Show this help.

Each workload records:
  - cow-active-capture: fresh image-backed writable COW capture.
  - sealed-layer-append: run from a sealed parent layer and capture a new layer.
  - sealed-layer-replay: boot from the captured sealed-layer chain and verify.
  - raw-rootfs-read: optional read-only --rootfs baseline when --raw-rootfs is set.

The raw baseline is read-only because the product CLI intentionally does not
expose a writable raw rootfs mode. Use the COW and sealed-layer rows for the
writable product path.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

positive_int() {
  local opt="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "${opt} must be a positive integer"
}

duration_ms() {
  local opt="$1"
  local value="$2"
  local number=""
  local multiplier=1000
  if [[ "${value}" =~ ^([0-9]+)ms$ ]]; then
    number="${BASH_REMATCH[1]}"
    multiplier=1
  elif [[ "${value}" =~ ^([0-9]+)s$ ]]; then
    number="${BASH_REMATCH[1]}"
    multiplier=1000
  elif [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    number="${BASH_REMATCH[1]}"
    multiplier=60000
  elif [[ "${value}" =~ ^([0-9]+)$ ]]; then
    number="${BASH_REMATCH[1]}"
    multiplier=1000
  else
    die "${opt} expects a duration like 60s, 500ms, or 1m"
  fi
  [[ "${number}" -gt 0 ]] || die "${opt} expects a positive duration"
  printf '%d\n' "$((number * multiplier))"
}

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1000000)'
}

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "${value}"
}

trim_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return 0
  fi
  head -c 4096 "${path}" | sed -e 's/[[:space:]]*$//'
}

infer_backend() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "hvf" ;;
    Linux-aarch64|Linux-arm64) echo "kvm" ;;
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); pass --backend" ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi

backend="auto"
sqlite_image="docker.io/library/python:3.12-alpine"
package_image="docker.io/library/alpine:3.20"
platform="linux/arm64"
workload="all"
iterations=3
memory_mib=1024
timeout_ms=180000
output=""
spore_bin="${REPO_ROOT}/zig-out/bin/spore"
raw_rootfs=""
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      need_value "$1" "${2-}"
      backend="$2"
      shift 2
      ;;
    --sqlite-image)
      need_value "$1" "${2-}"
      sqlite_image="$2"
      shift 2
      ;;
    --package-image)
      need_value "$1" "${2-}"
      package_image="$2"
      shift 2
      ;;
    --platform)
      need_value "$1" "${2-}"
      platform="$2"
      shift 2
      ;;
    --workload)
      need_value "$1" "${2-}"
      workload="$2"
      shift 2
      ;;
    -n|--iterations)
      need_value "$1" "${2-}"
      iterations="$2"
      shift 2
      ;;
    --memory-mib)
      need_value "$1" "${2-}"
      memory_mib="$2"
      shift 2
      ;;
    --timeout)
      need_value "$1" "${2-}"
      timeout_ms="$(duration_ms "$1" "$2")"
      shift 2
      ;;
    --timeout-ms)
      need_value "$1" "${2-}"
      timeout_ms="$2"
      shift 2
      ;;
    --output)
      need_value "$1" "${2-}"
      output="$2"
      shift 2
      ;;
    --spore-bin)
      need_value "$1" "${2-}"
      spore_bin="$2"
      shift 2
      ;;
    --raw-rootfs)
      need_value "$1" "${2-}"
      raw_rootfs="$2"
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
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${backend}" in
  auto) backend="$(infer_backend)" ;;
  hvf|kvm) ;;
  *) die "--backend must be auto, hvf, or kvm" ;;
esac
case "${workload}" in
  sqlite|package|all) ;;
  *) die "--workload must be sqlite, package, or all" ;;
esac
positive_int "--iterations" "${iterations}"
positive_int "--memory-mib" "${memory_mib}"
positive_int "--timeout" "${timeout_ms}"

if [[ "${build}" == "1" ]]; then
  (cd "${REPO_ROOT}" && mise run build)
fi
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

if [[ -z "${output}" ]]; then
  out_dir="${TMPDIR:-/tmp}/sporevm-writable-rootfs-benchmark"
  mkdir -p "${out_dir}"
  output="${out_dir}/$(date -u +%Y%m%dT%H%M%SZ).jsonl"
fi
mkdir -p "$(dirname "${output}")"
: >"${output}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-writable-rootfs-benchmark.XXXXXX")"
cleanup() {
  if [[ -z "${SPORE_KEEP_BENCH_WORKDIR:-}" ]]; then
    rm -rf "${workdir}"
  else
    echo "kept benchmark workdir: ${workdir}" >&2
  fi
}
trap cleanup EXIT

spore_image_common=(--backend "${backend}" --memory "${memory_mib}mb" --timeout "${timeout_ms}ms")
spore_from_common=(--backend "${backend}" --timeout "${timeout_ms}ms")

resolve_image() {
  local ref="$1"
  if [[ "${ref}" == *@sha256:* ]]; then
    printf '%s\n' "${ref}"
  else
    "${spore_bin}" rootfs resolve "${ref}" --platform "${platform}"
  fi
}

run_spore_capture() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2
  set +e
  "${spore_bin}" run "$@" >"${stdout_path}" 2>"${stderr_path}"
  local status=$?
  return "${status}"
}

emit_row() {
  local workload_name="$1"
  local mode="$2"
  local iteration="$3"
  local image_ref="$4"
  local status="$5"
  local duration_ms="$6"
  local stdout_path="$7"
  local stderr_path="$8"
  local spore_dir="$9"
  local stdout_trimmed
  local stderr_trimmed
  stdout_trimmed="$(trim_file "${stdout_path}")"
  stderr_trimmed="$(trim_file "${stderr_path}")"
  printf '{"workload":%s,"mode":%s,"iteration":%d,"backend":%s,"image":%s,"status":%d,"duration_ms":%d,"spore_dir":%s,"stdout":%s,"stderr":%s}\n' \
    "$(json_string "${workload_name}")" \
    "$(json_string "${mode}")" \
    "${iteration}" \
    "$(json_string "${backend}")" \
    "$(json_string "${image_ref}")" \
    "${status}" \
    "${duration_ms}" \
    "$(json_string "${spore_dir}")" \
    "$(json_string "${stdout_trimmed}")" \
    "$(json_string "${stderr_trimmed}")" \
    | tee -a "${output}" >/dev/null
}

timed_run() {
  local workload_name="$1"
  local mode="$2"
  local iteration="$3"
  local image_ref="$4"
  local stdout_path="$5"
  local stderr_path="$6"
  local spore_dir="$7"
  shift 7
  local start_ms
  local end_ms
  local status
  echo "benchmark ${workload_name} ${mode} iteration=${iteration}" >&2
  start_ms="$(now_ms)"
  set +e
  run_spore_capture "${stdout_path}" "${stderr_path}" "$@"
  status=$?
  set -e
  end_ms="$(now_ms)"
  emit_row "${workload_name}" "${mode}" "${iteration}" "${image_ref}" "${status}" "$((end_ms - start_ms))" "${stdout_path}" "${stderr_path}" "${spore_dir}"
  echo "benchmark ${workload_name} ${mode} iteration=${iteration} status=${status} duration_ms=$((end_ms - start_ms))" >&2
  if [[ "${status}" != "0" ]]; then
    cat "${stdout_path}" >&2 || true
    cat "${stderr_path}" >&2 || true
    die "${workload_name} ${mode} iteration ${iteration} failed"
  fi
}

sqlite_command='python3 -c '"'"'import sqlite3 as s,os;c=s.connect("file:/var/tmp/s.db?nolock=1",uri=1);c.execute("pragma journal_mode=off");c.execute("create table t(x)");c.executemany("insert into t values(?)",[(b"x"*2000,)]*1000);c.commit();os.sync();print("ok")'"'"''
sqlite_verify='test -s /var/tmp/s.db && echo sqlite-replay-ok'
sqlite_read='python3 -c '"'"'import sqlite3; c=sqlite3.connect("/var/tmp/s.db"); print(c.execute("select count(*) from t").fetchone()[0])'"'"''

package_command='i=0;mkdir -p /var/tmp/pkg/bin;while [ $i -lt 200 ];do dd if=/dev/zero of=/var/tmp/pkg/bin/f$i bs=4096 count=1 2>/dev/null;i=$(($i+1));done;sync;echo package-bench-ok'
package_verify='test -f /var/tmp/pkg/bin/f199 && echo package-replay-ok'
package_read='find /bin /sbin /usr/bin /usr/sbin -type f 2>/dev/null | wc -l'

run_workload() {
  local workload_name="$1"
  local image_ref="$2"
  local needs_net="$3"
  local command="$4"
  local verify="$5"
  local raw_read="$6"
  local resolved_image
  resolved_image="$(resolve_image "${image_ref}")"
  echo "benchmark workload=${workload_name} image=${image_ref} resolved=${resolved_image}" >&2

  for iteration in $(seq 1 "${iterations}"); do
    local iter_dir="${workdir}/${workload_name}-${iteration}"
    local base_dir="${iter_dir}/base.spore"
    local cow_dir="${iter_dir}/cow.spore"
    local layered_dir="${iter_dir}/layered.spore"
    mkdir -p "${iter_dir}"

    local net_args=()
    if [[ "${needs_net}" == "1" ]]; then
      net_args+=(--net)
    fi

    timed_run "${workload_name}" "base-layer-capture" "${iteration}" "${resolved_image}" \
      "${iter_dir}/base.stdout" "${iter_dir}/base.stderr" "${base_dir}" \
      "${spore_image_common[@]}" "${net_args[@]}" --image "${resolved_image}" --capture "${base_dir}" \
      -- /bin/sh -lc 'printf "base-layer\n" >/var/tmp/sporevm-bench-base && sync'

    timed_run "${workload_name}" "cow-active-capture" "${iteration}" "${resolved_image}" \
      "${iter_dir}/cow.stdout" "${iter_dir}/cow.stderr" "${cow_dir}" \
      "${spore_image_common[@]}" "${net_args[@]}" --image "${resolved_image}" --capture "${cow_dir}" \
      -- /bin/sh -lc "${command}"

    timed_run "${workload_name}" "sealed-layer-append" "${iteration}" "${resolved_image}" \
      "${iter_dir}/layered.stdout" "${iter_dir}/layered.stderr" "${layered_dir}" \
      "${spore_from_common[@]}" --from "${base_dir}" --capture "${layered_dir}" \
      -- /bin/sh -lc "${command}"

    timed_run "${workload_name}" "sealed-layer-replay" "${iteration}" "${resolved_image}" \
      "${iter_dir}/replay.stdout" "${iter_dir}/replay.stderr" "${layered_dir}" \
      "${spore_from_common[@]}" --from "${layered_dir}" \
      -- /bin/sh -lc "${verify}"

    if [[ -n "${raw_rootfs}" ]]; then
      timed_run "${workload_name}" "raw-rootfs-read" "${iteration}" "${raw_rootfs}" \
        "${iter_dir}/raw.stdout" "${iter_dir}/raw.stderr" "" \
        "${spore_image_common[@]}" --rootfs "${raw_rootfs}" \
        -- /bin/sh -lc "${raw_read}"
    fi
  done
}

if [[ "${workload}" == "sqlite" || "${workload}" == "all" ]]; then
  run_workload "sqlite" "${sqlite_image}" 0 "${sqlite_command}" "${sqlite_verify}" "${sqlite_read}"
fi
if [[ "${workload}" == "package" || "${workload}" == "all" ]]; then
  run_workload "package-install" "${package_image}" 0 "${package_command}" "${package_verify}" "${package_read}"
fi

echo "benchmark:writable-rootfs ok output=${output}"
