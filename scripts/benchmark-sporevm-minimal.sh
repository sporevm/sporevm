#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Benchmark the minimal SporeVM boot/exec path.

Usage:
  scripts/benchmark-sporevm-minimal.sh --backend hvf|kvm [options]

Options:
  --backend <name>          Backend to run: hvf or kvm.
  --kernel <path>           Linux kernel Image to boot (default: managed initrd kernel).
  --initrd <path>           Initrd to boot. If omitted, a minimal exec initrd is built.
  -n, --iterations <count>  Number of runs (default: 10).
  --memory-mib <mib>        Guest memory in MiB (default: 1024).
  --vcpus <count>           Guest vCPU count; must be 1 today.
  --guest-port <port>       Guest vsock listen port (default: 10700).
  --timeout-ms <ms>         Probe timeout in milliseconds (default: 30000).
  --output-dir <path>       JSONL output directory (default: benchmarks/results).
  --runner <path>           Prebuilt hvf-minimal/kvm-minimal runner path.
  --no-build                Do not run zig build for the runner.
  -h, --help                Show this help.

The measured probe boots the VM, connects to the guest vsock listener, sends a
JSON argv request for /bin/true, and records VM-start, vsock-connect, and
first-exec-response timings. It intentionally bypasses Cleanroom policy,
rootfs, gateway, repository, and control-plane behavior.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi

backend=""
kernel_path=""
initrd_path=""
iterations=10
memory_mib=1024
vcpus=1
guest_port=10700
timeout_ms=30000
output_dir="${REPO_ROOT}/benchmarks/results"
runner_path=""
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --vcpus)
      need_value "$1" "${2-}"
      vcpus="$2"
      shift 2
      ;;
    --guest-port)
      need_value "$1" "${2-}"
      guest_port="$2"
      shift 2
      ;;
    --timeout-ms)
      need_value "$1" "${2-}"
      timeout_ms="$2"
      shift 2
      ;;
    --output-dir)
      need_value "$1" "${2-}"
      output_dir="$2"
      shift 2
      ;;
    --runner)
      need_value "$1" "${2-}"
      runner_path="$2"
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

case "${backend}" in
  hvf|kvm) ;;
  "") usage >&2; exit 2 ;;
  *) die "--backend must be hvf or kvm" ;;
esac

if [[ -z "${kernel_path}" ]]; then
  kernel_path="$("${REPO_ROOT}/scripts/ensure-managed-kernel.sh" initrd)"
  echo "using managed kernel: ${kernel_path}" >&2
fi
[[ -f "${kernel_path}" ]] || die "kernel not found: ${kernel_path}"

for pair in \
  "iterations:${iterations}" \
  "memory-mib:${memory_mib}" \
  "vcpus:${vcpus}" \
  "guest-port:${guest_port}" \
  "timeout-ms:${timeout_ms}"
do
  name="${pair%%:*}"
  value="${pair#*:}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "--${name} must be a positive integer"
done

if [[ -z "${runner_path}" ]]; then
  runner_path="${REPO_ROOT}/zig-out/bin/${backend}-minimal"
fi

if [[ "${build}" == "1" ]]; then
  if command -v mise >/dev/null 2>&1; then
    (cd "${REPO_ROOT}" && mise exec -- zig build "${backend}-minimal")
  else
    (cd "${REPO_ROOT}" && zig build "${backend}-minimal")
  fi
fi
[[ -x "${runner_path}" ]] || die "runner not executable: ${runner_path}"

if [[ -z "${initrd_path}" ]]; then
  initrd_path="${REPO_ROOT}/zig-out/minimal-exec-initrd.cpio"
  "${REPO_ROOT}/scripts/make-minimal-exec-initrd.sh" "${initrd_path}" >/dev/null
fi
[[ -f "${initrd_path}" ]] || die "initrd not found: ${initrd_path}"

timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
output_path="${output_dir}/${timestamp}-sporevm-${backend}-minimal.jsonl"
console_dir="${output_dir}/${timestamp}-sporevm-${backend}-minimal-console"
mkdir -p "${console_dir}"
: >"${output_path}"

for i in $(seq 1 "${iterations}"); do
  console_log="${console_dir}/run-${i}.log"
  "${runner_path}" \
    --kernel "${kernel_path}" \
    --initrd "${initrd_path}" \
    --memory-mib "${memory_mib}" \
    --vcpus "${vcpus}" \
    --guest-port "${guest_port}" \
    --timeout-ms "${timeout_ms}" \
    --console-log "${console_log}" | tee -a "${output_path}"
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
    "exec_response_ms " + stat(map(.exec_response_ms)) + "\n" +
    "vsock_connect_ms " + stat(map(.vsock_connect_ms))
  ' "${output_path}"
fi
