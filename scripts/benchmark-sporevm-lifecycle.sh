#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Benchmark the named SporeVM lifecycle path.

Usage:
  scripts/benchmark-sporevm-lifecycle.sh --image REF [options]

Options:
  --image REF              OCI image to use for spore create. Prefer a digest-pinned linux/arm64 image.
  -n, --iterations N       Number of lifecycle runs (default: 10).
  --output-dir DIR         Directory for JSONL output and logs (default: /tmp/sporevm-lifecycle).
  --runtime-dir DIR        Runtime directory to reuse (default: <output-dir>/runtime).
  --rootfs-cache-dir DIR   Rootfs cache directory to pass as SPOREVM_ROOTFS_CACHE_DIR.
  --spore-bin PATH         Spore binary path (default: zig-out/bin/spore).
  --backend NAME           Backend for spore create (default: auto).
  --kernel PATH            Kernel Image path to pass through to create.
  --initrd PATH            Initrd path to pass through to create.
  --memory-mib N           Guest memory in MiB (default: 1024).
  --timeout-ms N           Exec/create timeout in milliseconds (default: 60000).
  --identity-command CMD   First command run in the VM (default: boot_id probe).
  --workload-command CMD   Second command run in the VM (default: node -v).
  --no-build               Do not run mise/zig build before benchmarking.
  -h, --help               Show this help.

The timed section starts immediately before `spore create`, runs the identity
probe and workload command with `spore exec`, then stops before `spore rm`.
Cleanup is recorded separately and is not included in create_to_node_ms.
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

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "${value}"
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.time_ns() // 1000000)'
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
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

trim_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return 0
  fi
  head -c 4096 "${path}" | sed -e 's/[[:space:]]*$//'
}

positive_int() {
  local opt="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "${opt} must be a positive integer"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi

image=""
iterations=10
output_dir="/tmp/sporevm-lifecycle"
runtime_dir=""
owned_runtime_dir=0
rootfs_cache_dir=""
spore_bin="${REPO_ROOT}/zig-out/bin/spore"
backend="auto"
kernel_path=""
initrd_path=""
memory_mib=1024
timeout_ms=60000
identity_command='cat /proc/sys/kernel/random/boot_id'
workload_command='node -v'
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      need_value "$1" "${2-}"
      image="$2"
      shift 2
      ;;
    -n|--iterations)
      need_value "$1" "${2-}"
      iterations="$2"
      shift 2
      ;;
    --output-dir)
      need_value "$1" "${2-}"
      output_dir="$2"
      shift 2
      ;;
    --runtime-dir)
      need_value "$1" "${2-}"
      runtime_dir="$2"
      shift 2
      ;;
    --rootfs-cache-dir)
      need_value "$1" "${2-}"
      rootfs_cache_dir="$2"
      shift 2
      ;;
    --spore-bin)
      need_value "$1" "${2-}"
      spore_bin="$2"
      shift 2
      ;;
    --backend)
      need_value "$1" "${2-}"
      backend="$2"
      shift 2
      ;;
    --kernel)
      need_value "$1" "${2-}"
      kernel_path="$2"
      shift 2
      ;;
    --initrd)
      need_value "$1" "${2-}"
      initrd_path="$2"
      shift 2
      ;;
    --memory-mib)
      need_value "$1" "${2-}"
      memory_mib="$2"
      shift 2
      ;;
    --timeout-ms)
      need_value "$1" "${2-}"
      timeout_ms="$2"
      shift 2
      ;;
    --identity-command)
      need_value "$1" "${2-}"
      identity_command="$2"
      shift 2
      ;;
    --workload-command)
      need_value "$1" "${2-}"
      workload_command="$2"
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
      exit 1
      ;;
  esac
done

[[ -n "${image}" ]] || { usage >&2; exit 2; }
positive_int "--iterations" "${iterations}"
positive_int "--memory-mib" "${memory_mib}"
positive_int "--timeout-ms" "${timeout_ms}"
case "${backend}" in
  auto|hvf|kvm) ;;
  *) die "--backend must be auto, hvf, or kvm" ;;
esac

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"
if [[ -z "${runtime_dir}" ]]; then
  runtime_dir="$(mktemp -d "/tmp/sporevm-lifecycle-runtime.XXXXXX")"
  owned_runtime_dir=1
fi
mkdir -p "${runtime_dir}"
runtime_dir="$(cd "${runtime_dir}" && pwd)"
chmod 700 "${runtime_dir}" 2>/dev/null || true

if [[ "${build}" == "1" ]]; then
  if command -v mise >/dev/null 2>&1; then
    (cd "${REPO_ROOT}" && mise run build)
  else
    (cd "${REPO_ROOT}" && zig build)
  fi
fi
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
output_path="${output_dir}/${timestamp}-sporevm-lifecycle.jsonl"
log_dir="${output_dir}/${timestamp}-logs"
mkdir -p "${log_dir}"
: >"${output_path}"
failures=0

spore_env=(SPOREVM_RUNTIME_DIR="${runtime_dir}")
if [[ -n "${rootfs_cache_dir}" ]]; then
  mkdir -p "${rootfs_cache_dir}"
  rootfs_cache_dir="$(cd "${rootfs_cache_dir}" && pwd)"
  spore_env+=(SPOREVM_ROOTFS_CACHE_DIR="${rootfs_cache_dir}")
fi

create_base=("${spore_bin}" create)
if [[ -n "${backend}" ]]; then
  create_base+=(--backend "${backend}")
fi
if [[ -n "${kernel_path}" ]]; then
  create_base+=(--kernel "${kernel_path}")
fi
if [[ -n "${initrd_path}" ]]; then
  create_base+=(--initrd "${initrd_path}")
fi
create_base+=(--image "${image}" --memory-mib "${memory_mib}" --timeout-ms "${timeout_ms}")

for i in $(seq 1 "${iterations}"); do
  vm_name="spore-life-${timestamp}-${i}"
  console_log="${log_dir}/${vm_name}-console.log"
  create_stdout="${log_dir}/${vm_name}-create.out"
  create_stderr="${log_dir}/${vm_name}-create.err"
  identity_stdout="${log_dir}/${vm_name}-identity.out"
  identity_stderr="${log_dir}/${vm_name}-identity.err"
  workload_stdout="${log_dir}/${vm_name}-workload.out"
  workload_stderr="${log_dir}/${vm_name}-workload.err"
  rm_stdout="${log_dir}/${vm_name}-rm.out"
  rm_stderr="${log_dir}/${vm_name}-rm.err"

  create_status=0
  identity_status=-1
  workload_status=-1
  rm_status=0

  start_ms="$(now_ms)"
  create_start_ms="${start_ms}"
  if run_capture "${create_stdout}" "${create_stderr}" \
    env "${spore_env[@]}" "${create_base[@]}" "${vm_name}" --console-log "${console_log}"; then
    create_status=0
  else
    create_status=$?
  fi
  create_end_ms="$(now_ms)"

  identity_start_ms="${create_end_ms}"
  if [[ "${create_status}" == "0" ]]; then
    if run_capture "${identity_stdout}" "${identity_stderr}" \
      env "${spore_env[@]}" "${spore_bin}" exec "${vm_name}" -- /bin/sh -lc "${identity_command}"; then
      identity_status=0
    else
      identity_status=$?
    fi
  fi
  identity_end_ms="$(now_ms)"

  workload_start_ms="${identity_end_ms}"
  if [[ "${identity_status}" == "0" ]]; then
    if run_capture "${workload_stdout}" "${workload_stderr}" \
      env "${spore_env[@]}" "${spore_bin}" exec "${vm_name}" -- /bin/sh -lc "${workload_command}"; then
      workload_status=0
    else
      workload_status=$?
    fi
  fi
  workload_end_ms="$(now_ms)"

  rm_start_ms="$(now_ms)"
  if run_capture "${rm_stdout}" "${rm_stderr}" env "${spore_env[@]}" "${spore_bin}" rm "${vm_name}"; then
    rm_status=0
  else
    rm_status=$?
  fi
  rm_end_ms="$(now_ms)"

  if [[ "${create_status}" != "0" || "${identity_status}" != "0" || "${workload_status}" != "0" || "${rm_status}" != "0" ]]; then
    failures=$((failures + 1))
  fi

  identity_output="$(trim_file "${identity_stdout}")"
  workload_output="$(trim_file "${workload_stdout}")"
  create_error="$(trim_file "${create_stderr}")"
  identity_error="$(trim_file "${identity_stderr}")"
  workload_error="$(trim_file "${workload_stderr}")"

  {
    printf '{'
    printf '"iteration":%d,' "${i}"
    printf '"vm_name":%s,' "$(json_string "${vm_name}")"
    printf '"image":%s,' "$(json_string "${image}")"
    printf '"backend":%s,' "$(json_string "${backend}")"
    printf '"memory_mib":%d,' "${memory_mib}"
    printf '"timeout_ms":%d,' "${timeout_ms}"
    printf '"create_to_node_ms":%d,' "$((workload_end_ms - start_ms))"
    printf '"create_ms":%d,' "$((create_end_ms - create_start_ms))"
    printf '"identity_exec_ms":%d,' "$((identity_end_ms - identity_start_ms))"
    printf '"workload_exec_ms":%d,' "$((workload_end_ms - workload_start_ms))"
    printf '"cleanup_ms":%d,' "$((rm_end_ms - rm_start_ms))"
    printf '"create_status":%d,' "${create_status}"
    printf '"identity_status":%d,' "${identity_status}"
    printf '"workload_status":%d,' "${workload_status}"
    printf '"rm_status":%d,' "${rm_status}"
    printf '"identity_output":%s,' "$(json_string "${identity_output}")"
    printf '"workload_output":%s,' "$(json_string "${workload_output}")"
    printf '"create_error":%s,' "$(json_string "${create_error}")"
    printf '"identity_error":%s,' "$(json_string "${identity_error}")"
    printf '"workload_error":%s,' "$(json_string "${workload_error}")"
    printf '"console_log":%s' "$(json_string "${console_log}")"
    printf '}\n'
  } >>"${output_path}"

  echo "lifecycle benchmark iteration ${i}/${iterations}: create_to_node_ms=$((workload_end_ms - start_ms)) status=${create_status}/${identity_status}/${workload_status} log=${console_log}" >&2
done

printf 'wrote %s\n' "${output_path}"

if command -v jq >/dev/null 2>&1; then
  jq -s -r '
    def round1: (. * 10 | round / 10);
    def stat($xs): ($xs | sort) as $s |
      "n=" + (($s|length)|tostring) +
      " median=" + ((if ($s|length)%2==1 then $s[(($s|length)/2|floor)] else (($s[(($s|length)/2)-1] + $s[(($s|length)/2)]) / 2) end)|round1|tostring) +
      " mean=" + (($s|add/length)|round1|tostring) +
      " min=" + ($s[0]|round1|tostring) +
      " max=" + ($s[-1]|round1|tostring);
    "create_to_node_ms " + stat(map(.create_to_node_ms)) + "\n" +
    "create_ms " + stat(map(.create_ms)) + "\n" +
    "identity_exec_ms " + stat(map(.identity_exec_ms)) + "\n" +
    "workload_exec_ms " + stat(map(.workload_exec_ms))
  ' "${output_path}"
fi

if [[ "${failures}" -gt 0 ]]; then
  die "${failures} lifecycle benchmark iteration(s) failed; see ${output_path}"
fi

if [[ "${owned_runtime_dir}" == "1" ]]; then
  rmdir "${runtime_dir}/vms" "${runtime_dir}" 2>/dev/null || true
fi
